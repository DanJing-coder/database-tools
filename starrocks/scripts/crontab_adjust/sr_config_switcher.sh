#!/bin/bash
# Description: 通用型 StarRocks 配置调整脚本 (带详细审计日志)
# Author: Gemini Assistant & User
# Date: 2026-04-03

# 1. 动态寻找 mysql 客户端 (保持通用性)
SEARCH_PATHS=($(which mysql 2>/dev/null) "/mysql/mysql8.0/bin/mysql" "/usr/bin/mysql")
MYSQL_BIN=""
for path in "${SEARCH_PATHS[@]}"; do
    [[ -x "$path" ]] && MYSQL_BIN="$path" && break
done

if [[ -z "$MYSQL_BIN" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] 找不到 mysql 客户端" >> "/home/starrocks/tools/log/sr_switch.log"
    exit 1
fi

# --- 配置区 ---
SR_HOST=""
SR_PORT="9030"
SR_USER=""
SR_PWD=""
LOG_FILE="/home/starrocks/tools/log/sr_switch.log"
VAR_NAME="big_query_profile_threshold"

# --- 逻辑处理 ---
ACTION=$1
case "$ACTION" in
    start) NEW_VAL="20s" ;;
    stop)  NEW_VAL="0s"  ;;
    *)
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Usage: $0 {start|stop}" >> "$LOG_FILE"
        exit 1
        ;;
esac

# 2. 【新增】获取修改前的值 (用于对比)
OLD_VAL=$($MYSQL_BIN -h${SR_HOST} -P${SR_PORT} -u${SR_USER} -p${SR_PWD} -N -s -e "SELECT @@global.$VAR_NAME;" 2>&1 | grep -v "Using a password")

# 3. 执行修改操作
$MYSQL_BIN -h${SR_HOST} -P${SR_PORT} -u${SR_USER} -p${SR_PWD} -e "SET GLOBAL $VAR_NAME = '$NEW_VAL';" 2>&1 | grep -v "Using a password" >> "$LOG_FILE"

# 4. 【增强】检查结果并打印详细审计日志
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    # 获取修改后的实际值进行二次确认
    FINAL_VAL=$($MYSQL_BIN -h${SR_HOST} -P${SR_PORT} -u${SR_USER} -p${SR_PWD} -N -s -e "SELECT @@global.$VAR_NAME;" 2>&1 | grep -v "Using a password")
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] User: $(whoami) | Action: $ACTION | Variable: $VAR_NAME | Change: [$OLD_VAL] -> [$FINAL_VAL] | Client: $MYSQL_BIN" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to change $VAR_NAME from $OLD_VAL to $NEW_VAL" >> "$LOG_FILE"
    exit 1
fi