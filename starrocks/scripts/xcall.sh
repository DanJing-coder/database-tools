#!/bin/bash

# 设置默认host文件路径
DEFAULT_HOST_FILE="/home/starrocks/tools/nodes/all_hosts"

# 显示帮助信息函数
show_help() {
    echo "用法: remote_exec [host_file_path] <command>"
    echo ""
    echo "在多个远程主机上执行命令的工具"
    echo ""
    echo "参数:"
    echo "  host_file            包含目标主机IP的文件，IP用逗号分隔"
    echo "  command              要在远程主机上执行的命令"
    echo ""
    echo "Opts:"
    echo "  -h, --help           显示此帮助信息"
    echo ""
    echo "Default:"
    echo "  If the host_file is not specified, $DEFAULT_HOST_FILE will be used."
    echo ""
    echo "eg:"
    echo "  remote_exec \"ls -l\"                      # 使用默认host文件执行命令"
    echo "  remote_exec hosts.txt \"df -h\"          # 指定host文件执行命令"
    echo ""
    echo "!!!!!!!!!!!!!!Please use with care!!!!!!!!!!!!!!!!"
    echo ""
}

# 解析命令行参数
if [ "$#" -eq 0 ]; then
    show_help
    exit 1
fi

# 检查是否请求帮助
for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        show_help
        exit 0
    fi
done

# 处理命令行参数
if [ "$#" -eq 1 ]; then
    # 如果只提供了一个参数，将其作为命令，使用默认host文件
    COMMAND="$1"
    HOST_FILE="$DEFAULT_HOST_FILE"
elif [ "$#" -eq 2 ]; then
    # 如果提供了两个参数，第一个作为host文件，第二个作为命令
    HOST_FILE="$1"
    COMMAND="$2"
else
    # 参数数量不对，显示用法信息
    echo "错误: 参数数量不正确" >&2
    show_help
    exit 1
fi

# 检查host文件是否存在
if [ ! -f "$HOST_FILE" ]; then
    echo "错误: host文件 '$HOST_FILE' 不存在" >&2
    exit 1
fi

# 读取host文件内容
host_content=$(cat "$HOST_FILE")

# 使用逗号分割IP地址
IFS=',' read -ra hosts <<< "$host_content"

# 遍历所有IP并执行命令
for host in "${hosts[@]}"; do
    # 去除首尾空格
    host=$(echo "$host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # 跳过空IP
    if [ -z "$host" ]; then
        continue
    fi
    
    echo "===== 在 $host 上执行命令: $COMMAND ====="
    
    # 使用SSH执行命令并显示输出
    ssh -o StrictHostKeyChecking=no "$host" "$COMMAND" 2>&1
    
    # 显示命令执行结果状态
    if [ $? -eq 0 ]; then
        echo "[$host] 命令执行成功"
    else
        echo "[$host] 命令执行失败"
    fi
    
    echo
done

exit 0 