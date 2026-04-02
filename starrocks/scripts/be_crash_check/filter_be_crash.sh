#!/bin/bash

# ==============================================================================
# 脚本名称: collect_be_crash_logs_pro.sh
# 功能: StarRocks BE宕机日志收集脚本 (去噪增强版)
# 特性: 自动过滤 JVM 日期解析错误、网络警告等无关噪音，只保留纯净堆栈
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# 显示用法
usage() {
    echo "用法: $0 [-h] [-d <date>] <hosts_file>"
    echo "选项:"
    echo "  -h          显示此帮助信息"
    echo "  -d <date>   指定日期，格式推荐 'MMM DD'，例如 'Jan 13' (默认: 当天)"
    echo "  <hosts_file> 包含BE节点IP地址的文本文件"
    exit 1
}

# 处理命令行参数
DATE_INPUT=""
while getopts "hd:" opt; do
    case $opt in
        h) usage; exit 0 ;;
        d) DATE_INPUT="$OPTARG" ;;
        *) usage; exit 1 ;;
    esac
done

shift $((OPTIND-1))

if [ $# -ne 1 ]; then
    log_error "必须指定hosts文件"
    usage
fi

HOSTS_FILE="$1"

# === 日期处理逻辑 ===
if [ -z "$DATE_INPUT" ]; then
    LOG_DIR_DATE=$(date '+%Y%m%d')
    TARGET_MONTH=$(date '+%b')
    TARGET_DAY=$(date '+%d')
else
    if ! date -d "$DATE_INPUT" >/dev/null 2>&1; then
        log_error "日期格式无法识别: $DATE_INPUT"
        exit 1
    fi
    LOG_DIR_DATE=$(date -d "$DATE_INPUT" '+%Y%m%d')
    TARGET_MONTH=$(date -d "$DATE_INPUT" '+%b')
    TARGET_DAY=$(date -d "$DATE_INPUT" '+%d')
fi

# 去掉日期的前导0 (例如 "05" -> "5")，适配日志格式
DAY_NUM=$(echo "$TARGET_DAY" | sed 's/^0//')
# 构建正则 (适配 "Jan  5" 或 "Jan 13" 这种中间可能有多个空格的情况)
DATE_REGEX="${TARGET_MONTH}[[:space:]]+0?${DAY_NUM}"

OUTPUT_DIR="be_crash_logs_${LOG_DIR_DATE}"
SUMMARY_FILE="${OUTPUT_DIR}/summary_${LOG_DIR_DATE}.txt"

log_info "目标日期: $LOG_DIR_DATE (匹配正则: '$DATE_REGEX')"
log_info "输出目录: $OUTPUT_DIR"

if [ ! -f "$HOSTS_FILE" ]; then
    log_error "hosts文件不存在: $HOSTS_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# 初始化摘要
{
    echo "StarRocks BE宕机日志收集摘要"
    echo "脚本执行时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "故障目标日期: $LOG_DIR_DATE"
    echo "Hosts文件: $HOSTS_FILE"
    echo "=========================================="
    echo ""
} > "$SUMMARY_FILE"

TOTAL_HOSTS=0
SUCCESS_HOSTS=0
FAILED_HOSTS=0

while IFS= read -r line || [ -n "$line" ]; do
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then continue; fi

    IFS=',' read -ra IPS <<< "$line"
    for ip in "${IPS[@]}"; do
        ip=$(echo "$ip" | xargs)
        if [ -z "$ip" ]; then continue; fi

        TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
        echo -e "${CYAN}>>> 处理节点: $ip${NC}"

        NODE_LOG_FILE="${OUTPUT_DIR}/crash_log_${ip}_${LOG_DIR_DATE}.log"
        TEMP_LOG="${NODE_LOG_FILE}.tmp"

        {
            echo "=== 节点 $ip 的宕机日志 ==="
            echo "提取时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
        } > "$NODE_LOG_FILE"

        # SSH 远程执行 Awk 提取
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$ip" bash > "$TEMP_LOG" 2>/dev/null << EOF
    
    # 1. 自动定位 be.out
    be_out_file=""
    # 尝试通过进程定位
    be_pid=\$(pgrep -x starrocks_be | head -n 1)
    if [ -n "\$be_pid" ]; then
        exe_path=\$(readlink -f /proc/\$be_pid/exe 2>/dev/null)
        if [ -n "\$exe_path" ]; then
            be_home=\$(dirname \$(dirname "\$exe_path"))
            if [ -f "\$be_home/log/be.out" ]; then
                be_out_file="\$be_home/log/be.out"
            fi
        fi
    fi
    # 尝试通过默认路径定位
    if [ -z "\$be_out_file" ]; then
        target_dir=\$(ls -td /starrocks/be-* 2>/dev/null | head -1)
        if [ -n "\$target_dir" ] && [ -f "\$target_dir/log/be.out" ]; then
             be_out_file="\$target_dir/log/be.out"
        elif [ -f "/starrocks/be/log/be.out" ]; then
             be_out_file="/starrocks/be/log/be.out"
        fi
    fi

    if [ -z "\$be_out_file" ]; then
        echo "NOT_FOUND"
        exit 1
    fi

    # 2. Awk 核心提取逻辑 (去噪版)
    awk -v d_regex="$DATE_REGEX" '
    BEGIN {
        in_block = 0
        buffer = ""
        has_stack_content = 0
    }

    # [规则1] 匹配堆栈开始 (如 branch-3.x RELEASE)
    /RELEASE.*\(build/ {
        in_block = 1
        buffer = \$0
        has_stack_content = 0
        next
    }

    # [规则2] 匹配结束标志 (start time: ...)
    /^start time:/ {
        if (in_block) {
            # 只有当包含实际堆栈内容且日期匹配时才打印
            if (has_stack_content && \$0 ~ d_regex) {
                print buffer
                print \$0
                print "--------------------------------------------------"
                print ""
            }
        }
        in_block = 0
        buffer = ""
        has_stack_content = 0
        next
    }

    # [规则3] 块内处理与过滤
    in_block {
        # === 噪音过滤区 (直接跳过这些行) ===
        if (\$0 ~ /DateTime parsing error/) next;
        if (\$0 ~ /Error from accept/) next;
        if (\$0 ~ /Run with JEMALLOC_CONF/) next;
        if (\$0 ~ /Duplicate assignment/) next;
        if (\$0 ~ /Java HotSpot/) next;
        
        # === 有效性标记 ===
        # 如果包含 SIGSEGV, Aborted, query_id 或 堆栈帧(@ 0x), 视为有效堆栈
        if (\$0 ~ /SIGSEGV|SIGABRT|Aborted|query_id|PC: @|^\s*@/) {
            has_stack_content = 1
        }

        # 累加有效内容
        buffer = buffer "\n" \$0
    }
    ' "\$be_out_file"
EOF

        # 检查 SSH 执行状态
        if [ $? -ne 0 ]; then
            if grep -q "NOT_FOUND" "$TEMP_LOG"; then
                log_warn "节点 $ip: 未找到 be.out 文件"
                echo "Error: be.out not found" >> "$NODE_LOG_FILE"
            else
                log_warn "节点 $ip: SSH连接失败或执行异常"
                echo "Error: SSH Failed" >> "$NODE_LOG_FILE"
            fi
            FAILED_HOSTS=$((FAILED_HOSTS + 1))
            rm -f "$TEMP_LOG" 2>/dev/null
            continue
        fi

        # 将过滤后的内容写入最终日志
        cat "$TEMP_LOG" >> "$NODE_LOG_FILE"
        rm -f "$TEMP_LOG" 2>/dev/null

        # 统计结果
        if grep -q "RELEASE.*(build" "$NODE_LOG_FILE"; then
            count=$(grep -c "^start time:" "$NODE_LOG_FILE" || echo 0)
            log_info "节点 $ip: 成功提取 $count 次纯净堆栈"
            SUCCESS_HOSTS=$((SUCCESS_HOSTS + 1))
            echo "节点: $ip | 状态: 成功 | 宕机次数: $count" >> "$SUMMARY_FILE"
        else
            log_info "节点 $ip: 无匹配日期的宕机日志"
            echo "无相关日志" >> "$NODE_LOG_FILE"
            echo "节点: $ip | 状态: 无日志" >> "$SUMMARY_FILE"
        fi
    done
done < "$HOSTS_FILE"

echo "------------------------------------------" >> "$SUMMARY_FILE"
echo "总数: $TOTAL_HOSTS, 成功: $SUCCESS_HOSTS, 失败: $FAILED_HOSTS" >> "$SUMMARY_FILE"
log_info "收集完成! 汇总: $SUMMARY_FILE"