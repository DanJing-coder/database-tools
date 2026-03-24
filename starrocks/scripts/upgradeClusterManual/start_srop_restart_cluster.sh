#!/bin/bash

# 彩色输出函数
function echo_color() {
    case "$1" in
        "green")  echo -e "\033[32;40m$2\033[0m" ;;
        "red")    echo -e "\033[31;40m$2\033[0m" ;;
        "yellow") echo -e "\033[33;40m$2\033[0m" ;;
        "blue")   echo -e "\033[34;40m$2\033[0m" ;;
        *)        echo "$2" ;;
    esac
}

# 检查节点免密连接
function check_node_connection() {
    local exe_user=$(whoami)
    if ! ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 "${exe_user}@${1}" "pwd" &>/dev/null; then
        echo_color red "${1} 节点免密未打通，跳过操作"
        return 1
    fi
    return 0
}

# 获取 agent 安装路径(返回 agentctl.sh 完整路径)
function get_agent_path_be_name() {
    local hostname=$1
    local exe_user=$(whoami)
    
    # 从进程信息提取 agent 路径(匹配包含 agent_service/agent_service 的进程)
    local agent_path=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "ps -ef | grep 'agent_service/agent_service' | grep -v grep | awk '{print \$(NF-2)}' | sed 's/\/agent.*//' | head -n 1" 2>/dev/null)
    # 清理路径并拼接 agentctl.sh
    agent_path=$(echo "$agent_path" | awk '{print $NF}')
    if [ -z "$agent_path" ]; then
      agent_path="/opt/starrocks"
    fi

    agent_ctl="${agent_path}/agentctl.sh"
    super_be_path=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "ls ${agent_path}/agent/supervisor/conf.d/ | grep be | awk -F'.' '{print \$1}' ") 
    
    # 验证路径有效性
    if [ -z "$agent_path" ] || [ "$agent_path" = "/" ] || [ "$agent_path" = "." ]; then
        echo ""
        return 1
    fi
    
    # 检查 agentctl.sh 是否存在
    local ctl_exists=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "[ -f '${agent_ctl}' ] && echo 'exists' || echo 'not exists'" 2>/dev/null)
    if [ "$ctl_exists" != "exists" ]; then
        echo ""
        return 1
    fi
    
    echo "$agent_ctl,$super_be_path"
    return 0
}


# 执行 agent 操作(start/stop/restart)
function execute_agent_operation() {
    local hostname=$1
    local operation=$2  # 操作类型:start/stop/restart
    local exe_user=$(whoami)

    # 获取 agentctl.sh 路径
    local agent_path_be_name=$(get_agent_path_be_name "$hostname")
    IFS=',' read -r agent_ctl be_name <<< "$agent_path_be_name"

    if [ -z "$agent_ctl" ]; then
        echo_color red "${hostname} Get agentctl path failed!"
        return 1
    fi

    #获取 BE 名称
    if [ -z "$be_name" ]; then
        echo_color red "${hostname} Get be name failed!"
        return 1
    fi

    # 执行操作并捕获结果
    echo_color blue "${hostname} Begin:${operation}"
    local result=$(ssh -o ConnectTimeout=10 "${exe_user}@${hostname}" \
        "${agent_ctl} ${operation} ${be_name}" 2>&1)
    local exit_code=$?

    # 输出执行结果
    if [ $exit_code -eq 0 ]; then
        echo_color green "${hostname} Operate successfully:${operation}"
        echo "Result:${result}"
    else
        echo_color red "${hostname} Operate failed (Exit_code:${exit_code})"
        echo "Error message:${result}"
    fi

    echo_color yellow "=== ${hostname} 节点操作结束 ===\n"
    return $exit_code
}

# 显示帮助信息
function show_help() {
    echo "用法: $0 [选项] <节点列表文件|单个节点>"
    echo "功能: 远程对节点执行 agentctl.sh 的 start/stop/restart 操作"
    echo "选项:"
    echo "  -s    执行 start 操作"
    echo "  -t    执行 stop 操作"
    echo "  -r    执行 restart 操作(默认)"
    echo "参数说明:"
    echo "  <目标>        节点列表文件(每行一个节点或用逗号分隔)或单个节点主机名/IP"
    echo "示例:"
    echo "  $0 -r be_nodes.txt    # 对文件中所有节点执行 restart 操作(默认)"
    echo "  $0 -s 192.168.1.100   # 对单个节点执行 start 操作"
    echo "  $0 -t node_list.txt   # 对文件中所有节点执行 stop 操作"
    exit 1
}

# 主函数:解析参数并批量执行操作
function main() {
    # 解析选项(默认操作:restart)
    local operation="restart"
    while getopts "strh" opt; do
        case $opt in
            s) operation="start" ;;
            t) operation="stop" ;;
            r) operation="restart" ;;
            h) show_help ;;
            \?) echo_color red "无效选项: -$OPTARG" >&2; show_help ;;
        esac
    done
    shift $((OPTIND - 1))  # 移除已解析的选项

    # 检查参数是否足够(需指定目标节点)
    if [ $# -ne 1 ]; then
        echo_color red "参数错误:请指定节点列表文件或单个节点"
        show_help
    fi
    local target=$1

    # 解析目标节点列表
    local node_list=()
    if [ -f "$target" ]; then
        # 从文件读取节点(支持逗号分隔或行分隔)
        local content=$(cat "$target")
        if [[ "$content" == *","* ]]; then
            # 逗号分隔格式(去除空格和空项)
            IFS=',' read -ra nodes <<< "$content"
            for node in "${nodes[@]}"; do
                node=$(echo "$node" | tr -d '[:space:]')
                if [ -n "$node" ]; then
                    node_list+=("$node")
                fi
            done
            echo_color blue "已从文件加载逗号分隔节点列表，共 ${#node_list[@]} 个节点"
        else
            # 行分隔格式(忽略空行和注释)
            while IFS= read -r line; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                node_list+=("$line")
            done < "$target"
            echo_color blue "已从文件加载行分隔节点列表，共 ${#node_list[@]} 个节点"
        fi
    else
        # 单个节点
        node_list=("$target")
        echo_color blue "目标节点: ${target}，执行操作: ${operation}"
    fi

    # 检查节点列表是否为空
    if [ ${#node_list[@]} -eq 0 ]; then
        echo_color red "未找到有效节点，请检查输入文件或节点名称"
        exit 1
    fi

    # 对每个节点执行操作
    for node in "${node_list[@]}"; do
        if [ -z "$node" ]; then
            continue  # 跳过空项
        fi
        if check_node_connection "$node"; then
            execute_agent_operation "$node" "$operation"
        else
            echo_color red "跳过无法连接的节点: ${node}\n"
        fi
        sleep 5
    done
}

# 启动主程序
main "$@"