#!/bin/bash

# 填入 Broker 列表，支持逗号或空格分隔
BROKERS="192.168.1.1:9092,192.168.1.2:9092,192.168.1.3:9092"

IFS=',' read -ra ADDR_ARRAY <<< "${BROKERS// /}"

echo "--- 使用 Bash /dev/tcp 进行网络检测 ---"

for addr in "${ADDR_ARRAY[@]}"; do
    host=${addr%:*}
    port=${addr#*:}

    # 使用 timeout 防止长时间挂起
    # (echo > /dev/tcp/host/port) 尝试建立连接
    timeout 2 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo "[ OK ] $host:$port"
    else
        echo "[FAIL] $host:$port <--- 连接失败"
    fi
done