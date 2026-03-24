#!/bin/bash

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
    
    # 从进程信息提取BE路径
    local be_path=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "ps -ef | grep starrocks_be | grep -v grep | grep -v gdb | awk '{print \$8}' | sed 's/\/lib.*//' | head -n 1" 2>/dev/null)
    be_path=$(echo "$be_path" | awk '{print $NF}')  # 清理路径中的空格和特殊字符
    
    # 验证路径有效性
    if [ -z "$be_path" ] || [ "$be_path" = "/" ] || [ "$be_path" = "." ]; then
        echo ""
        return 1
    fi
    echo "$be_path"
    return 0
}

# 获取FE安装路径
get_fe_path() {
    local hostname=$1
    local exe_user=$(whoami)
    
    # 从进程信息提取FE路径
    local fe_path=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "ps -ef | grep \"com.starrocks.StarRocksFE\" | grep -v \"grep\" | grep -oP '(?<=-Xlog:gc\*:).*(?=/log/fe\.gc\.log)' | head -n 1" 2>/dev/null)
    fe_path=$(echo "$fe_path" | awk '{print $NF}')  # 清理路径中的空格和特殊字符
    
    # 验证路径有效性
    if [ -z "$fe_path" ] || [ "$fe_path" = "/" ] || [ "$fe_path" = "." ]; then
        echo ""
        return 1
    fi
    echo "$fe_path"
    return 0
}

# 获取Broker安装路径
get_broker_path() {
    local hostname=$1
    local exe_user=$(whoami)
    
    # 从进程信息提取Broker路径
    local broker_path=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "ps -ef | grep start_broker | grep -v \"grep\" | grep -oP '(?<=bash\s).+(?=/bin/)' | head -n 1" 2>/dev/null)
    broker_path=$(echo "$broker_path" | awk '{print $NF}')  # 清理路径中的空格和特殊字符
    
    # 验证路径有效性
    if [ -z "$broker_path" ] || [ "$broker_path" = "/" ] || [ "$broker_path" = "." ]; then
        echo ""
        return 1
    fi
    echo "$broker_path"
    return 0
}

# 备份指定组件的conf目录
backup_component_conf() {
    local hostname=$1
    local component=$2  # be, fe, broker
    local exe_user=$(whoami)
    
    local component_path
    local component_conf_path
    local component_desc
    
    case "$component" in
        "be")
            component_path=$(get_be_path "$hostname")
            component_conf_path="${component_path}/conf"
            component_desc="BE"
            ;;
        "fe")
            component_path=$(get_fe_path "$hostname")
            component_conf_path="${component_path}/conf"
            component_desc="FE"
            ;;
        "broker")
            component_path=$(get_broker_path "$hostname")
            component_conf_path="${component_path}/conf"
            component_desc="Broker"
            ;;
        *)
            echo_color red "不支持的组件类型: $component"
            return 1
            ;;
    esac
    
    # 检查路径是否获取成功
    if [ -z "$component_path" ]; then
        echo_color red "无法获取 ${hostname} 的${component_desc}安装路径，跳过备份"
        return 1
    fi
    
    # 检查conf目录是否存在
    local conf_exists=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
        "[ -d '${component_conf_path}' ] && echo 'exists' || echo 'not exists'" 2>/dev/null)
    if [ "$conf_exists" != "exists" ]; then
        echo_color red "${hostname} 的${component_desc}配置目录不存在: ${component_conf_path},请检查用户是否正确"
        return 1
    fi
    
    # 创建备份目录名称（与原conf同级目录，加上日期后缀）
    local date_suffix=$(date +"%Y%m%d")
    local backup_conf_path="${component_path}/conf_backup_${date_suffix}"
    
    # 备份配置文件
    echo_color yellow "=== 备份 ${hostname} 的${component_desc}配置文件 ==="
    echo "源路径: ${component_conf_path}"
    echo "备份路径: ${backup_conf_path}"
    
    # 在远程节点上使用cp命令进行备份
    local backup_result=$(ssh -o ConnectTimeout=10 "${exe_user}@${hostname}" " \
        if [ -d '${backup_conf_path}' ]; then \
            rm -rf '${backup_conf_path}'; \
        fi; \
        cp -r '${component_conf_path}' '${backup_conf_path}' 2>&1 \
    ")
    
    if [ $? -ne 0 ]; then
        echo_color red "复制${component_desc}配置文件失败: ${backup_result}"
        return 1
    fi
    
    echo_color green "${component_desc}配置文件备份成功: ${backup_conf_path}"
    echo ""
    return 0
}

# 备份节点上的所有指定组件的配置
backup_node_configs() {
    local hostname=$1
    local components=$2  # be,fe,broker 或它们的组合
    
    # 解析组件列表
    IFS=',' read -ra component_list <<< "$components"
    
    for component in "${component_list[@]}"; do
        component=$(echo "$component" | tr -d '[:space:]')  # 去除空格
        if [ -n "$component" ]; then
            backup_component_conf "$hostname" "$component"
        fi
    done
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项] <组件类型> <目标>"
    echo "功能: 远程备份StarRocks FE、BE或Broker节点的配置文件到与原conf同级目录下"
    echo "选项:"
    echo "  -h    显示帮助信息"
    echo "参数说明:" 
    echo "  <组件类型>    要备份的组件类型，可以是be、fe、broker或它们的组合（用逗号分隔，如be,fe）"
    echo "  <目标>        节点列表文件（每行一个节点或用逗号分隔的节点）或单个节点主机名/IP"
    echo "备份说明：配置文件将备份到与原conf目录同级的目录下，备份目录名为conf_backup_YYYYMMDD格式"
    echo "示例:" 
    echo "  $0 be be_nodes.txt    # 备份所有BE节点的配置文件到与原conf同级目录下"
    echo "  $0 be,fe node1        # 备份node1节点的BE和FE配置文件到与原conf同级目录下"
    echo "  $0 broker 192.168.1.100  # 备份单个Broker节点的配置文件到与原conf同级目录下"
    exit 1
}

# 主函数：解析参数并批量执行
main() {
    # 解析选项
    while getopts "h" opt; do
        case "$opt" in
            h) show_help ;;
            *) show_help ;;
        esac
    done
    shift $((OPTIND-1))
    
    # 检查参数数量
    if [ $# -ne 2 ]; then
        show_help
    fi
    
    local components=$1
    local target=$2
    
    # 验证组件类型
    if ! [[ "$components" =~ ^(be|fe|broker)(,(be|fe|broker))*$ ]]; then
        echo_color red "无效的组件类型: $components"
        echo "组件类型必须是be、fe、broker或它们的组合（用逗号分隔）"
        exit 1
    fi
    
    # 解析目标节点列表
    local node_list=()
    if [ -f "$target" ]; then
        # 从文件读取节点
        local content=$(cat "$target")
        
        # 检查是否包含逗号，如果包含则按逗号分割，否则按行分割
        if [[ "$content" == *","* ]]; then
            # 逗号分隔格式
            IFS=',' read -ra nodes <<< "$content"
            for node in "${nodes[@]}"; do
                node=$(echo "$node" | tr -d '[:space:]')  # 去除空格
                if [ -n "$node" ]; then
                    node_list+=("$node")
                fi
            done
            echo_color blue "已从文件加载逗号分隔节点列表，共 ${#node_list[@]} 个节点"
        else
            # 按行分隔格式
            while IFS= read -r line; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                node_list+=($line)
            done < "$target"
            echo_color blue "已从文件加载行分隔节点列表，共 ${#node_list[@]} 个节点"
        fi
    else
        # 单个节点
        node_list=("$target")
        echo_color blue "目标节点: ${target}"
    fi
    
    # 对每个节点执行备份
    for node in "${node_list[@]}"; do
        if [ -z "$node" ]; then
            continue  # 跳过空行
        fi
        if check_node_connection "$node"; then
            backup_node_configs "$node" "$components"
        else
            echo_color red "跳过无法连接的节点: ${node}\n"
        fi
    done
}

# 启动主程序
main "$@"