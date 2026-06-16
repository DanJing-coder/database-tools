#!/bin/bash

# --- 配置区域：请根据实际情况修改 Doris/StarRocks 的连接信息 ---
FE_HOST=""      # FE 的 IP
FE_PORT=""           # FE 的 MySQL 端口
DB_USER=""           # 拥有 ADMIN 权限的用户名
DB_PASS=""  # 密码（如果没有密码留空 ""）
# ------------------------------------------------------------

# 检查参数
if [ -z "$1" ]; then
    echo "错误: 请输入 BE 的 IP 或其片段！"
    echo "用法: $0 <BE_IP_OR_KEYWORD>"
    echo "示例: $0 dbr20   或  $0 dwh-dbr20-lp2"
    exit 1
fi

INPUT_IP="$1"
echo "============================================="
echo "开始处理，输入关键字: ${INPUT_IP}"
echo "============================================="

# 导出密码到环境变量，完美解决特殊字符问题
if [ -n "$DB_PASS" ]; then
    export MYSQL_PWD="$DB_PASS"
fi

# 构造 mysql 基础命令数组（使用数组可以优雅处理带空格/特殊字符的参数）
MYSQL_OPTS=(-h"${FE_HOST}" -P"${FE_PORT}" -u"${DB_USER}" -sN)

# 1. 获取所有的 BackendId 和 IP 列表
echo "正在从 FE 获取 Backend 列表..."
BE_LIST=$(mysql "${MYSQL_OPTS[@]}" -e "SHOW BACKENDS;")

if [ -z "$BE_LIST" ]; then
    echo "错误: 无法获取 Backend 列表，请检查 FE 连接配置、密码或权限。"
    exit 1
fi

# 2. 根据输入的参数进行模糊匹配
# 使用 grep -v '^$' 代替了原脚本未定义的自定义函数
MATCHED_BE=$(echo "$BE_LIST" | awk '{print $1, $2}' | grep "$INPUT_IP")
MATCHED_COUNT=$(echo "$MATCHED_BE" | grep -v '^$' | wc -l)

if [ "$MATCHED_COUNT" -eq 0 ]; then
    echo "错误: 未找到匹配 '${INPUT_IP}' 的 BE 节点。"
    exit 1
elif [ "$MATCHED_COUNT" -gt 1 ]; then
    echo "错误: 匹配到多个 BE 节点，请提供更精确的 IP！"
    echo "匹配到的列表如下:"
    echo "$MATCHED_BE"
    exit 1
fi

# 3. 提取最终的 BackendId 和 完整的 IP
BE_ID=$(echo "$MATCHED_BE" | awk '{print $1}')
FULL_IP=$(echo "$MATCHED_BE" | awk '{print $2}')

echo "成功匹配到唯一 BE 节点:"
echo " -> BE ID: ${BE_ID}"
echo " -> 完整 IP: ${FULL_IP}"
echo "---------------------------------------------"

# 4. 执行获取 pstack 的命令并输出到文件
OUTPUT_FILE="be_${FULL_IP}_pstack_$(date +%Y%m%d_%H%M%S).log"
SQL_EXEC="ADMIN EXECUTE ON ${BE_ID} 'System.print(ExecEnv.get_stack_trace_for_all_threads())';"

echo "正在执行 SQL 命令并将堆栈信息导出到文件..."
echo "执行的 SQL: ${SQL_EXEC}"

# 执行并重定向到文件（注意变量都要加双引号）
mysql "${MYSQL_OPTS[@]}" -e "${SQL_EXEC}" > "${OUTPUT_FILE}"

if [ $? -eq 0 ] && [ -s "${OUTPUT_FILE}" ]; then
    echo "============================================="
    echo "执行成功！"
    echo "BE 堆栈信息已成功保存至文件: ${OUTPUT_FILE}"
    echo "============================================="
else
    echo "错误: 执行失败或输出文件为空，请检查 FE/BE 日志或用户权限。"
    exit 1
fi