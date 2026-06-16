#!/bin/bash

# --- 参数说明 ---
# $1: BE IP 文件路径
# $2: Tablet ID
# $3: 输出目录路径

# 检查参数个数是否满足要求
if [ "$#" -lt 3 ]; then
    echo "使用方法: $0 <IP文件路径> <TabletID> <输出目录>"
    echo "示例: $0 ./be_ips.txt 3133589722 ./backup_meta"
    exit 1
fi

# 获取命令行参数
IP_FILE=$1
TABLET_ID=$2
OUTPUT_DIR=$3
BE_PORT=8040

# --- 脚本逻辑 ---

# 1. 检查输入文件是否存在
if [ ! -f "$IP_FILE" ]; then
    echo "错误: IP文件 '$IP_FILE' 不存在，请检查路径。"
    exit 1
fi

# 2. 创建输出目录（如果不存在则创建）
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "输出目录 '$OUTPUT_DIR' 不存在，正在创建..."
    mkdir -p "$OUTPUT_DIR"
fi

# 3. 解析 IP 文件（支持逗号分隔或空格/换行分隔）
# tr 将逗号替换为换行，sed 去除可能的首尾空格，最后读取
ips=$(cat "$IP_FILE" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//')

echo "------------------------------------------"
echo "开始任务:"
echo "  输入文件: $IP_FILE"
echo "  Tablet ID: $TABLET_ID"
echo "  输出目录: $OUTPUT_DIR"
echo "------------------------------------------"

# 4. 循环请求
for ip in $ips; do
    if [ -z "$ip" ]; then
        continue
    fi

    # 构造输出文件名
    output_file="${OUTPUT_DIR}/meta_${ip}_${TABLET_ID}.json"
    
    echo -n "正在请求 BE $ip ... "
    
    # 执行 curl
    # -w "%{http_code}" 可以获取 HTTP 状态码
    http_code=$(curl -s -o "$output_file" --connect-timeout 5 -w "%{http_code}" "http://${ip}:${BE_PORT}/api/meta/header/${TABLET_ID}")
    
    if [ "$http_code" == "200" ]; then
        echo "成功 [HTTP 200]"
    else
        echo "失败 [HTTP $http_code]"
        # 如果失败，删除生成的空文件或错误信息文件（可选）
        [ -f "$output_file" ] && rm "$output_file"
    fi
done

echo "------------------------------------------"
echo "任务执行完毕。"