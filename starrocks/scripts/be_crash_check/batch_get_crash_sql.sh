#!/bin/bash

# ==============================================================================
# 脚本名称: batch_get_crash_sql.sh
# 功能: 批量从 BE 宕机日志中提取 QueryID，并自动根据目录日期反查 SQL 语句
# 依赖: 需要与 get_query_sql.sh (优化版) 配合使用
# 用法: ./batch_get_crash_sql.sh <crash_logs_directory>
# 示例: ./batch_get_crash_sql.sh be_crash_logs_20251230
# ==============================================================================

set -u

# --- 配置区 ---
# 请确保这里指向你刚才优化的 SQL 溯源脚本路径
QUERY_SQL_SCRIPT="./get_query_sql.sh" 

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 检查依赖 ---
if [ ! -f "$QUERY_SQL_SCRIPT" ]; then
    echo -e "${RED}[ERROR] 找不到 SQL 溯源脚本: $QUERY_SQL_SCRIPT${NC}"
    echo "请修改脚本中的 QUERY_SQL_SCRIPT 变量指向正确路径。"
    exit 1
fi

# 添加执行权限
chmod +x "$QUERY_SQL_SCRIPT"

# --- 参数检查 ---
if [ $# -ne 1 ]; then
    echo "用法: $0 <宕机日志目录>"
    echo "示例: $0 be_crash_logs_20260105"
    exit 1
fi

LOG_DIR="$1"

# 检查目录是否存在
if [ ! -d "$LOG_DIR" ]; then
    echo -e "${RED}[ERROR] 目录不存在: $LOG_DIR${NC}"
    exit 1
fi

# --- 新增: 智能日期推断逻辑 ---
# 1. 去除目录路径末尾可能的斜杠
CLEAN_DIR_PATH="${LOG_DIR%/}"
# 2. 获取纯目录名 (例如 be_crash_logs_20260105)
DIR_BASENAME=$(basename "$CLEAN_DIR_PATH")
# 3. 初始化日期参数为空
DATE_ARG=""
DETECTED_DATE_STR=""

# 4. 正则匹配 8位数字 (YYYYMMDD)
if [[ "$DIR_BASENAME" =~ ([0-9]{8}) ]]; then
    RAW_DATE="${BASH_REMATCH[1]}"
    
    # 尝试验证并格式化日期 (兼容 Linux date 命令)
    if date -d "$RAW_DATE" +%Y-%m-%d >/dev/null 2>&1; then
        FORMATTED_DATE=$(date -d "$RAW_DATE" +%Y-%m-%d)
        DATE_ARG="-d $FORMATTED_DATE"
        DETECTED_DATE_STR="$FORMATTED_DATE"
        echo -e "${GREEN}[INFO] 从目录名识别到故障日期: ${CYAN}${FORMATTED_DATE}${NC}"
    else
        echo -e "${YELLOW}[WARN] 目录名包含数字 '$RAW_DATE' 但无法识别为有效日期，将默认查询当天。${NC}"
    fi
else
    echo -e "${YELLOW}[WARN] 目录名 '$DIR_BASENAME' 中未发现日期信息(YYYYMMDD)，将默认查询当天。${NC}"
fi

# 输出文件
RESULT_FILE="${LOG_DIR}/final_crash_sql_summary_$(date +%Y%m%d_%H%M%S).txt"

# --- 步骤 1: 提取并去重 QueryID ---
echo -e "${GREEN}[INFO] 正在从 $LOG_DIR 中提取 QueryID...${NC}"

# 创建临时文件保存 ID 列表
TEMP_ID_FILE=$(mktemp)

# 提取逻辑
grep -h -oE "query_id:[0-9a-fA-F-]{36}" "$LOG_DIR"/crash_log_*.log 2>/dev/null | \
    awk -F':' '{print $2}' | \
    sort | uniq > "$TEMP_ID_FILE"

# 统计 ID 数量
ID_COUNT=$(wc -l < "$TEMP_ID_FILE")

if [ "$ID_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}[WARN] 未在日志文件中找到任何 QueryID。请检查日志格式。${NC}"
    rm "$TEMP_ID_FILE"
    exit 0
fi

echo -e "${GREEN}[INFO] 共发现 $ID_COUNT 个去重后的 QueryID。${NC}"
cat "$TEMP_ID_FILE"
echo "----------------------------------------"

# --- 步骤 2: 批量反查 SQL ---
echo -e "${GREEN}[INFO] 开始反查 SQL (结果将写入 $RESULT_FILE)...${NC}"

# 初始化结果文件
{
    echo "=================================================================="
    echo "BE 宕机 QueryID SQL 溯源汇总"
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "日志源目录: $LOG_DIR"
    if [ -n "$DETECTED_DATE_STR" ]; then
        echo "指定查询日期: $DETECTED_DATE_STR"
    else
        echo "指定查询日期: 默认 (当天)"
    fi
    echo "QueryID 总数: $ID_COUNT"
    echo "=================================================================="
    echo ""
} > "$RESULT_FILE"

CURRENT_IDX=1
SUCCESS_COUNT=0
FAIL_COUNT=0

while read -r QID; do
    echo -ne "[$CURRENT_IDX/$ID_COUNT] 处理 ID: $QID ... "
    
    echo "------------------------------------------------------------------" >> "$RESULT_FILE"
    echo "QueryID: $QID" >> "$RESULT_FILE"
    
    # 调用 get_query_sql.sh 并传入自动识别的日期参数 ($DATE_ARG)
    # 这里的 "$DATE_ARG" 会展开为 "-d 2026-01-05" 或者为空
    # 必须去掉引号以允许参数展开，或者确保变量内含有的空格被正确处理
    # 最安全的方式是直接把变量放进去，bash会处理空变量
    
    SQL_OUTPUT=$("$QUERY_SQL_SCRIPT" -q "$QID" $DATE_ARG 2>&1)
    
    # 简单的成功判断逻辑
    if echo "$SQL_OUTPUT" | grep -qE "SELECT|INSERT|ALTER|CREATE|SHOW|DELETE|UPDATE|WITH"; then
        echo -e "${GREEN}成功${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "状态: 成功获取 SQL" >> "$RESULT_FILE"
        echo "详情:" >> "$RESULT_FILE"
        echo "$SQL_OUTPUT" >> "$RESULT_FILE"
    else
        echo -e "${RED}失败 (未找到)${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "状态: 未找到对应的 SQL" >> "$RESULT_FILE"
        echo "执行日志:" >> "$RESULT_FILE"
        echo "$SQL_OUTPUT" | sed 's/^/  /' >> "$RESULT_FILE" # 缩进日志
    fi
    
    echo "" >> "$RESULT_FILE"
    
    CURRENT_IDX=$((CURRENT_IDX + 1))
    
done < "$TEMP_ID_FILE"

# --- 结束清理 ---
rm "$TEMP_ID_FILE"

echo -e "${GREEN}[INFO] 处理完成!${NC}"
echo -e "成功: $SUCCESS_COUNT, 失败: $FAIL_COUNT"
echo -e "汇总报告已生成: ${YELLOW}$RESULT_FILE${NC}"