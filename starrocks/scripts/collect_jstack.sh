#!/usr/bin/env bash

# 使用方式示例：
#   ./collect_jstack.sh 118293
#   ./collect_jstack.sh 123456     # 换成你的 FE 进程号
#   nohup ./collect_jstack.sh 118293 >/dev/null 2>&1 &

if [ $# -ne 1 ]; then
    echo "用法: $0 <pid>"
    echo "示例: $0 118293"
    exit 1
fi

PID="$1"
TOTAL_SECONDS=900          # 15分钟
INTERVAL=5                 # 每5秒采集一次
MAX_LOOPS=$((TOTAL_SECONDS / INTERVAL))

# 简单检查进程是否存在
if ! ps -p "${PID}" >/dev/null 2>&1; then
    echo "错误：进程 ${PID} 不存在或无权限访问"
    exit 1
fi

echo "开始采集 jstack，目标进程 PID=${PID}"
echo "采集频率：每 ${INTERVAL} 秒一次"
echo "最大运行时间：${TOTAL_SECONDS} 秒（约 ${MAX_LOOPS} 次）"
echo "按 Ctrl+C 可提前停止"
echo "----------------------------------------"

count=0
start_time=$(date +%s)

while [ $count -lt $MAX_LOOPS ]; do
    timestamp=$(date +"%Y%m%d_%H%M%S")
    filename="jstack_${PID}_${timestamp}.txt"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 采集第 $((count+1)) 次 → ${filename}"
    
    jstack "${PID}" > "${filename}" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "警告：jstack 执行失败（进程 ${PID} 可能已退出）"
        break
    fi
    
    count=$((count + 1))
    
    # 检查实际已用时间，防止 sleep 被中断导致累积误差
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -ge $TOTAL_SECONDS ]; then
        echo "已达到 ${TOTAL_SECONDS} 秒限制，停止采集"
        break
    fi
    
    sleep "${INTERVAL}"
done

end_time=$(date +%s)
total_time=$((end_time - start_time))

echo "----------------------------------------"
echo "采集结束"
echo "目标进程   : ${PID}"
echo "共采集次数 : ${count}"
echo "总耗时     : ${total_time} 秒"
echo "输出文件前缀: jstack_${PID}_*.txt"