#!/bin/bash
# 脚本功能是备份 StarRocks BE 节点的 log 目录到与 log 同级目录下
# 备份目录名为 log_backup_YYYYMMDD 格式。支持单个节点或多个节点（通过文件或逗号分隔）。
# 脚本会检查节点免密连接和 BE 安装路径的有效性，并提供彩色输出提示。

# 彩色输出函数
echo_color() {
    case "$1" in
        "green")  echo -e "\033[32;40m$2\033[0m" ;;
        "red")    echo -e "\033[31;40m$2\033[0m" ;;
        "yellow") echo -e "\033[33;40m$2\033[0m" ;;
        "blue")   echo -e "\033[34;40m$2\033[0m" ;;
        *)        echo "$2" ;;
    esac
}

# 检查节点免密连接
check_node_connection() {
    local exe_user=$(whoami)
    if ! ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 "${exe_user}@${1}" "pwd" &>/dev/null; then
        echo_color red "${1} 节点免密未打通，跳过备份"
        return 1
    fi
    return 0
}

# 获取BE安装路径
get_be_path() {
    local hostname=$1
    local exe_user=$(whoami)

    local be_path=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "ps -ef | grep starrocks_be | grep -v grep | grep -v gdb | awk '{print \$8}' | sed 's/\/lib.*//' | head -n 1" 2>/dev/null)
    be_path=$(echo "$be_path" | awk '{print $NF}')

    if [ -z "$be_path" ] || [ "$be_path" = "/" ] || [ "$be_path" = "." ]; then
        echo ""
        return 1
    fi
    echo "$be_path"
    return 0
}

# 备份 BE log 目录
backup_be_log() {
    local hostname=$1
    local exe_user=$(whoami)

    local be_path
    be_path=$(get_be_path "$hostname")

    if [ -z "$be_path" ]; then
        echo_color red "无法获取 ${hostname} 的 BE 安装路径，跳过备份"
        return 1
    fi

    local log_path="${be_path}/log"
    local log_exists
    log_exists=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "[ -d '${log_path}' ] && echo 'exists' || echo 'not exists'" 2>/dev/null)
    if [ "$log_exists" != "exists" ]; then
        echo_color red "${hostname} 的 BE 日志目录不存在: ${log_path}，请检查用户是否正确"
        return 1
    fi

    local date_suffix
    date_suffix=$(date +"%Y%m%d")
    local backup_log_path="${be_path}/log_backup_${date_suffix}"

    echo_color yellow "=== 备份 ${hostname} 的 BE 日志目录 ==="
    echo "源路径: ${log_path}"
    echo "备份路径: ${backup_log_path}"

    local backup_result
    backup_result=$(ssh -o ConnectTimeout=30 "${exe_user}@${hostname}" " \
        if [ -d '${backup_log_path}' ]; then \
            rm -rf '${backup_log_path}'; \
        fi; \
        cp -r '${log_path}' '${backup_log_path}' 2>&1 \
    ")

    if [ $? -ne 0 ]; then
        echo_color red "复制 BE 日志目录失败: ${backup_result}"
        return 1
    fi

    echo_color green "BE 日志目录备份成功: ${backup_log_path}"
    echo ""
    return 0
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项] <目标>"
    echo "功能: 远程备份 StarRocks BE 节点的 log 目录到与 log 同级目录下"
    echo "选项:"
    echo "  -h    显示帮助信息"
    echo "参数说明:"
    echo "  <目标>    节点列表文件（每行一个节点或用逗号分隔的节点）或单个节点主机名/IP"
    echo "备份说明: log 目录将备份到与 log 同级目录下，备份目录名为 log_backup_YYYYMMDD 格式"
    echo "示例:"
    echo "  $0 be_nodes.txt       # 备份文件中所有 BE 节点的日志"
    echo "  $0 192.168.1.100      # 备份单个 BE 节点的日志"
    exit 1
}

# 主函数
main() {
    while getopts "h" opt; do
        case "$opt" in
            h) show_help ;;
            *) show_help ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ $# -ne 1 ]; then
        show_help
    fi

    local target=$1
    local node_list=()

    if [ -f "$target" ]; then
        local content
        content=$(cat "$target")

        if [[ "$content" == *","* ]]; then
            IFS=',' read -ra nodes <<< "$content"
            for node in "${nodes[@]}"; do
                node=$(echo "$node" | tr -d '[:space:]')
                if [ -n "$node" ]; then
                    node_list+=("$node")
                fi
            done
            echo_color blue "已从文件加载逗号分隔节点列表，共 ${#node_list[@]} 个节点"
        else
            while IFS= read -r line; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                node_list+=("$line")
            done < "$target"
            echo_color blue "已从文件加载行分隔节点列表，共 ${#node_list[@]} 个节点"
        fi
    else
        node_list=("$target")
        echo_color blue "目标节点: ${target}"
    fi

    for node in "${node_list[@]}"; do
        if [ -z "$node" ]; then
            continue
        fi
        if check_node_connection "$node"; then
            backup_be_log "$node"
        else
            echo_color red "跳过无法连接的节点: ${node}"
            echo ""
        fi
    done
}

main "$@"
