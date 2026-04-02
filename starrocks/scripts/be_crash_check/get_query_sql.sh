#!/bin/bash

# ==============================================================================
# 脚本名称: retrieve_query_sql_pro_fixed.sh
# 功能: StarRocks QueryID 溯源与 SQL 提取工具 (并发版 - 修复当下查询Bug)
# 更新: 增加忽略特定用户功能
# ==============================================================================

set -u

# ============== 配置区 (请根据实际环境修改) ==============
SR_HOST="$fe_ip"
SR_PORT=9030
SR_USER="$user"
SR_PASSWORD=""

# 要忽略的审计日志用户名 (例如监控账号或系统采集账号)
IGNORE_USER=""

# FE 节点列表
FE_NODES=(
    "node1"
    "node2"
    "node3"
)

SSH_USER="starrocks"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no"

# ============== 辅助函数 ==============
log_info() { echo -e "\033[32m[INFO]\033[0m $(date '+%H:%M:%S') $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $(date '+%H:%M:%S') $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $(date '+%H:%M:%S') $1"; }

show_help() {
    echo "用法: $0 -q <QueryID> [-d <YYYY-MM-DD>]"
    exit 0
}

# ============== 参数解析 ==============
DATE=$(date '+%Y-%m-%d')
INPUT_QUERY_ID=""

while getopts ":d:q:h" opt; do
    case "$opt" in
        d) DATE="$OPTARG" ;;
        q) INPUT_QUERY_ID="$OPTARG" ;;
        h) show_help ;;
        *) log_error "未知选项: -$OPTARG"; show_help ;;
    esac
done

if [[ -z "$INPUT_QUERY_ID" ]]; then
    log_error "QueryID 不能为空"
    exit 1
fi

DATE_NODASH=$(date -d "$DATE" '+%Y%m%d')
TODAY_NODASH=$(date '+%Y%m%d') # 获取今天的日期字符串用于对比

SEARCH_QUERY_ID="$INPUT_QUERY_ID"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log_info "正在处理 QueryID: $INPUT_QUERY_ID (查询日期: $DATE)"
if [[ -n "$IGNORE_USER" ]]; then
    log_info "配置已启用过滤，将忽略用户: $IGNORE_USER"
fi

# ==============================================================================
# 阶段一: ID 溯源 (并发查 fe.log)
# ==============================================================================
log_info ">>> 阶段一: 检查 QueryID 是否存在映射转换..."

scan_fe_mapping() {
    local node=$1
    local qid=$2
    local date_compact=$3
    local is_today=$4

    ssh $SSH_OPTS "$SSH_USER@$node" "
        log_dir=\$(ps -ef | grep 'com.starrocks.StarRocksFE' | grep -v grep | grep -o '/starrocks/fe-[^/]*/log' | head -1)
        if [ -n \"\$log_dir\" ]; then
            # 构建文件列表
            files=\"\$log_dir/fe.log.$date_compact*\"
            
            # 如果是今天，额外追加 active 的 fe.log
            if [ \"$is_today\" == \"1\" ]; then
                files=\"\$files \$log_dir/fe.log\"
            fi
            
            # 查找 transfer 记录
            grep -h \"transfer QueryId: .* to $qid\" \$files 2>/dev/null | head -1
        fi
    " > "$TEMP_DIR/mapping_$node.txt" &
}

# 判断是否查今天
IS_TODAY=0
if [ "$DATE_NODASH" == "$TODAY_NODASH" ]; then
    IS_TODAY=1
    log_info "检测到查询日期为今天，将包含活跃日志文件 (fe.log)"
fi

# 并发执行
for node in "${FE_NODES[@]}"; do
    scan_fe_mapping "$node" "$INPUT_QUERY_ID" "$DATE_NODASH" "$IS_TODAY"
done
wait

# 汇总结果
MAPPED_ID=""
for file in "$TEMP_DIR"/mapping_*.txt; do
    if [ -s "$file" ]; then
        CONTENT=$(cat "$file")
        MAPPED_ID=$(echo "$CONTENT" | sed -n 's/.*transfer QueryId: \(.*\) to .*/\1/p')
        if [[ -n "$MAPPED_ID" ]]; then
            log_info "发现映射! 节点: $(basename "$file" .txt | sed 's/mapping_//')"
            log_info "原记录: $CONTENT"
            break
        fi
    fi
done

if [[ -n "$MAPPED_ID" && "$MAPPED_ID" != "$INPUT_QUERY_ID" ]]; then
    SEARCH_QUERY_ID="$MAPPED_ID"
    log_info "ID 转换成功: [Internal] $INPUT_QUERY_ID -> [Audit] $SEARCH_QUERY_ID"
else
    log_info "未发现 ID 转换记录，假设输入即为审计 ID。"
fi

# ==============================================================================
# 阶段二: 查询审计表 (MySQL)
# ==============================================================================
log_info ">>> 阶段二: 查询 starrocks_audit_tbl__ ..."

START_TIME="${DATE} 00:00:00"
END_TIME="${DATE} 23:59:59"

# [修改点] SQL中增加 user 过滤条件
SQL_USER_FILTER=""
if [[ -n "$IGNORE_USER" ]]; then
    SQL_USER_FILTER="AND user != '$IGNORE_USER'"
fi

SQL="SELECT stmt FROM starrocks_audit_db__.starrocks_audit_tbl__ 
     WHERE timestamp BETWEEN '$START_TIME' AND '$END_TIME' 
     AND queryId = '$SEARCH_QUERY_ID' 
     $SQL_USER_FILTER 
     LIMIT 1;"

DB_RESULT=$(mysql -h"$SR_HOST" -P"$SR_PORT" -u"$SR_USER" ${SR_PASSWORD:+-p"$SR_PASSWORD"} -N -e "$SQL" 2>/dev/null || true)

if [[ -n "$DB_RESULT" ]]; then
    echo -e "\n\033[32m================ [FOUND IN DB] ================\033[0m"
    echo "$DB_RESULT"
    echo -e "\033[32m===============================================\033[0m\n"
    exit 0
else
    log_warn "审计表中未找到 (或属于忽略用户)，准备搜索 FE 物理文件..."
fi

# ==============================================================================
# 阶段三: 并发搜索 FE 审计日志
# ==============================================================================
log_info ">>> 阶段三: 并发搜索所有 FE 节点的 fe.audit.log ..."

scan_fe_audit() {
    local node=$1
    local qid=$2
    local date_compact=$3
    local is_today=$4
    local ignore_user=$5 # [修改点] 接收忽略的用户参数

    ssh $SSH_OPTS "$SSH_USER@$node" "
        log_dir=\$(ps -ef | grep 'com.starrocks.StarRocksFE' | grep -v grep | grep -o '/starrocks/fe-[^/]*/log' | head -1)
        if [ -n \"\$log_dir\" ]; then
            # 构建文件列表
            files=\"\$log_dir/fe.audit.log.$date_compact*\"
            
            if [ \"$is_today\" == \"1\" ]; then
                files=\"\$files \$log_dir/fe.audit.log\"
            fi

            # [修改点] 增加 grep -v 过滤特定用户
            # 先 grep QueryID，再反向过滤 internal 表查询，再反向过滤特定用户
            if [ -n \"$ignore_user\" ]; then
                grep -h \"$qid\" \$files 2>/dev/null | grep -v 'starrocks_audit_tbl__' | grep -v \"User=$ignore_user\" | head -1
            else
                grep -h \"$qid\" \$files 2>/dev/null | grep -v 'starrocks_audit_tbl__' | head -1
            fi
        fi
    " > "$TEMP_DIR/audit_$node.txt" &
}

# 并发执行
for node in "${FE_NODES[@]}"; do
    # [修改点] 传入 IGNORE_USER 变量
    scan_fe_audit "$node" "$SEARCH_QUERY_ID" "$DATE_NODASH" "$IS_TODAY" "$IGNORE_USER"
done
wait

# 检查结果
FOUND_IN_FILE=0
for file in "$TEMP_DIR"/audit_*.txt; do
    if [ -s "$file" ]; then
        NODE_NAME=$(basename "$file" .txt | sed 's/audit_//')
        echo -e "\n\033[32m================ [FOUND IN FILE @ $NODE_NAME] ================\033[0m"
        cat "$file"
        echo -e "\033[32m==========================================================\033[0m\n"
        FOUND_IN_FILE=1
        break 
    fi
done

if [ $FOUND_IN_FILE -eq 0 ]; then
    log_error "所有手段均未找到 QueryID: $SEARCH_QUERY_ID 的 SQL 语句。"
    log_error "可能原因: 1. 日期错误 2. 属于被忽略的用户 ($IGNORE_USER) 3. 未开启审计"
    exit 1
fi