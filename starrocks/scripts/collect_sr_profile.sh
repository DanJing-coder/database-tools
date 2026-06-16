#!/bin/bash

# ================= 配置区 =================
DB_HOST="dwh-dbr18-lp2"
DB_PORT="9030"
DB_USER=""
DB_PASS=""
SAVE_DIR="/home/starrocks/tools/starrocks_profiles"
QUERY_TIMEOUT=20000  # 毫秒单位，对应你要求的20s

# 确保保存目录存在
mkdir -p "$SAVE_DIR"

# ================= 1. 检查执行时间窗 (00:00 - 06:00) =================
CURRENT_HOUR=$(date +%H)
if [ "$CURRENT_HOUR" -lt 0 ] || [ "$CURRENT_HOUR" -ge 6 ]; then
    # 不在时间窗内，退出脚本
    exit 0
fi

echo "--- 开始执行采集任务: $(date '+%Y-%m-%d %H:%M:%S') ---"

# ================= 2. 获取满足条件的 Query ID 列表 =================
# 注意：我们将 $__timeFilter 转换为 timestamp >= NOW() - INTERVAL 15 MINUTE
QUERY_SQL="
SELECT queryId 
FROM starrocks_audit_db__.starrocks_audit_tbl__ 
WHERE timestamp >= NOW() - INTERVAL 15 MINUTE
  AND queryTime > $QUERY_TIMEOUT
  AND User = 'yevseyev_30149'
  AND Digest = '46711bf283397c52f843f8547ac46a1c'
ORDER BY queryTime DESC;
"

# 执行查询并获取 ID 列表
query_ids=$(mysql -h${DB_HOST} -P${DB_PORT} -u${DB_USER} -p${DB_PASS} -N -s -e "${QUERY_SQL}")

if [ -z "$query_ids" ]; then
    echo "未发现符合条件的查询。"
    exit 0
fi

# ================= 3. 循环采集 Profile 并去重 =================
for qid in $query_ids; do
    TARGET_FILE="${SAVE_DIR}/profile_${qid}.txt"

    # 检查是否已采集过
    if [ -f "$TARGET_FILE" ]; then
        echo "QueryID: ${qid} 已采集过，跳过。"
        continue
    fi

    echo "正在采集 QueryID: ${qid} ..."
    
    # 执行 get_query_profile 并保存
    # 使用 -N (无标题) 和 -s (静默模式) 获取纯文本输出
    mysql -h${DB_HOST} -P${DB_PORT} -u${DB_USER} -p${DB_PASS} -N -s -e "SELECT get_query_profile('${qid}');" > "$TARGET_FILE"

    if [ $? -eq 0 ]; then
        echo "成功保存至: ${TARGET_FILE}"
    else
        echo "采集失败: ${qid}"
        rm -f "$TARGET_FILE" # 失败则清理掉空文件
    fi
done

echo "--- 任务结束 ---"