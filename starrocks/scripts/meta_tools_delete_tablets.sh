#!/bin/bash

# 这个脚本的功能是根据输入的 Tablet ID 列表（可以是文件或直接输入），在 /data* 目录下查找对应的目录路径，并生成删除元数据的命令。它支持三种输入方式：文件输入、直接输入和带逗号的输入。

# 获取输入：可以是文件名，也可以是直接排列的 ID
input=$*

# 1. 初始化 ID 列表
tablet_ids=""

if [ -f "$1" ]; then
    # 如果第一个参数是文件，读取内容并将逗号替换为空格
    tablet_ids=$(tr ',' ' ' < "$1")
    echo "# 正在从文件 [$1] 读取数据..." >&2
else
    # 否则，直接从命令行参数获取并处理可能的逗号
    tablet_ids=$(echo "$*" | tr ',' ' ')
fi

# 2. 判空处理
if [ -z "$tablet_ids" ]; then
    echo "使用说明:"
    echo "  方式1 (文件): $0 ids.txt"
    echo "  方式2 (直接输入): $0 9141633401 9163649605"
    echo "  方式3 (带逗号输入): $0 9141633401,9163649605"
    exit 1
fi

# 3. 循环处理
for id in $tablet_ids; do
    # 查找路径 (限制类型为目录，取第一个匹配项)
    # 增加 -maxdepth 提高效率（如果已知 data 目录下层级不多）
    full_path=$(find /data* -name "$id" -type d 2>/dev/null | head -n 1)

    if [ -n "$full_path" ]; then
        # 截取前三段路径: /data16/be-20250214...
        root_path=$(echo "$full_path" | cut -d'/' -f1-3)

        # 打印生成的命令
        echo "./meta_tool.sh --operation=delete_meta --root_path=$root_path --tablet_id=$id"
    else
        echo "# [错误] 未找到 Tablet ID: $id" >&2
    fi
done