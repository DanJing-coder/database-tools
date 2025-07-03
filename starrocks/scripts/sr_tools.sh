#!/bin/bash

exe_user=$(whoami)

function echo_color() {
    case "$1" in
        "green")  echo -e "\033[32;40m$2\033[0m" ;;
        "red")    echo -e "\033[31;40m$2\033[0m" ;;
        "yellow") echo -e "\033[33;40m$2\033[0m" ;;
        "blue")   echo -e "\033[34;40m$2\033[0m" ;;
        *)        echo "$2" ;;
    esac
}

# Execute the command on other nodes and return the results.
function sshcheck() {
    ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 "${exe_user}@${1}" "${2}" 2>/dev/null
}

# Execute the command on other nodes without returning results(for update operations).
function sshUpdate() {
    ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 "${exe_user}@${1}" "${2}" >/dev/null 2>&1
}

function check_node_connection() {
    if ! sshcheck "$1" "pwd" &>/dev/null; then
        echo_color red "${1} 节点免密未打通"
        return 1
    fi
    return 0
}

function recheck() {
    local hostname=$1
    local pid=$2
    
    echo_color yellow "检查 ${hostname} 节点的 core 打印开关:"
    echo_color blue "当前进程限制:"
    sshcheck "$hostname" "cat /proc/$pid/limits | grep \"Max core file size\" | grep -v grep | awk '{print \"Soft Limit:\" \$5, \"Hard Limit:\" \$6}'"
    
    echo_color blue "limits.conf 设置:"
    sshcheck "$hostname" 'grep "^.*soft.*core" /etc/security/limits.conf | grep -v \#'
    sshcheck "$hostname" 'grep "^.*hard.*core" /etc/security/limits.conf | grep -v \#'
}

# Toggle the core printing switch
function change_core_set() {
    local hostname=$1
    
    echo_color yellow "正在更改 ${hostname} 节点的 core 打印开关..."
    
    # 获取BE进程ID
    local be_pid=$(sshcheck "$hostname" "ps -ef | grep /lib/starrocks_be | grep -v grep | awk -F\" \" '{print \$2}' | head -n 1")
    local super_pid=$(sshcheck "$hostname" "ps -ef | grep /lib/starrocks_be | grep -v grep | awk -F\" \" '{print \$3}' | head -n 1")
    
    # 如果未找到BE进程，尝试查找start_be.sh进程
    if [ -z "$be_pid" ]; then
        be_pid=$(sshcheck "$hostname" "ps -ef | grep /bin/start_be.sh | grep -v grep | awk -F\" \" '{print \$2}' | head -n 1")
        super_pid=$(sshcheck "$hostname" "ps -ef | grep /bin/start_be.sh | grep -v grep | awk -F\" \" '{print \$3}' | head -n 1")
    fi
    
    # 验证是否找到进程ID
    if [ -z "$be_pid" ]; then
        echo_color red "未找到BE进程或start_be.sh进程"
        return 1
    fi
    
    # 动态修改BE进程和supervisor进程的core输出限制
    sshUpdate "$hostname" "prlimit -p ${be_pid} --core=0"
    sshUpdate "$hostname" "prlimit -p ${super_pid} --core=0"
    
    # 备份并修改配置文件
    sshUpdate "$hostname" 'sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak'
    
    if [[ -z $(sshcheck "$hostname" 'grep "^.*soft.*core" /etc/security/limits.conf') ]]; then
        sshUpdate "$hostname" 'echo "* soft core 0" | sudo tee -a /etc/security/limits.conf'
    else
        sshUpdate "$hostname" 'sudo sed -i "/soft.*core/s/unlimited/0/" /etc/security/limits.conf'
    fi
    
    if [[ -z $(sshcheck "$hostname" 'grep "^.*hard.*core" /etc/security/limits.conf') ]]; then
        sshUpdate "$hostname" 'echo "* hard core 0" | sudo tee -a /etc/security/limits.conf'
    else
        sshUpdate "$hostname" 'sudo sed -i "/hard.*core/s/unlimited/0/" /etc/security/limits.conf'
    fi
    
    # 检查配置
    recheck "$hostname" "$be_pid"
}

# 向be.conf中增加配置
function addConf2BEs() {
    local hostname=$1
    local config=$2
    
    echo_color yellow "正在向 ${hostname} 节点的be.conf添加配置..."
    
    # 获取BE路径
    local be_path=$(sshcheck "$hostname" "ps -ef | grep starrocks_be | grep -v grep | grep -v gdb | awk '{print \$8}' | sed 's/\/lib.*//' | head -n 1")
    be_path=$(echo "$be_path" | awk '{print $NF}')
    
    if [ -z "$be_path" ]; then
        echo_color red "无法确定BE路径"
        return 1
    fi
    
    local conf_path="${be_path}/conf/be.conf"
    local backup_path="${conf_path}_$(date +%Y%m%d)" 
    
    # 创建备份
    echo_color blue "正在备份原始配置文件..."
    if ! sshUpdate "$hostname" "sudo cp -f ${conf_path} ${backup_path}"; then
        echo_color red "备份失败，取消操作"
        return 1
    fi
    echo_color green "配置文件已备份至: ${backup_path}"
    
    # 添加配置
    echo_color blue "正在添加新配置..."
    if ! sshUpdate "$hostname" "echo '${config}' | sudo tee -a ${conf_path}"; then
        echo_color red "配置添加失败，尝试恢复原文件"
        sshUpdate "$hostname" "sudo cp -f ${backup_path} ${conf_path}"
        return 1
    fi
    
    # 验证配置是否添加成功
    echo_color blue "正在验证配置..."
    if sshcheck "$hostname" "grep -q '${config}' ${conf_path}"; then
        echo_color green "配置已成功添加到 ${conf_path}"
    else
        echo_color red "配置验证失败，恢复原文件"
        sshUpdate "$hostname" "sudo cp -f ${backup_path} ${conf_path}"
        return 1
    fi
}

# 搜索BE日志 - 支持传入搜索参数
function grep_be_log() {
    local hostname=$1
    local search_pattern=$2
    
    echo_color yellow "checking ${hostname} be.out..."

    # 如果未提供搜索模式，使用默认值
    if [ -z "$search_pattern" ]; then
        search_pattern="bc4df468-3fae-11f0-8d8f-58a2e1a95f4c"
    fi
    
    echo_color yellow "正在搜索 ${hostname} 节点的BE日志（模式: ${search_pattern}）..."
    
    # 获取BE路径
    local be_path=$(sshcheck "$hostname" "ps -ef | grep starrocks_be | grep -v grep | grep -v gdb | sed 's/\/lib.*//' | head -n 1")
    be_path=$(echo "$be_path" | awk '{print $NF}')
    
    if [ -z "$be_path" ]; then
        echo_color red "无法确定BE路径"
        return 1
    fi
    
    local log_path="${be_path}/log/be.out"
    
    # 搜索日志
    local result=$(sshcheck "$hostname" "grep -a '${search_pattern}' ${log_path}")
    
    if [ -n "$result" ]; then
        echo_color green "${hostname}: 找到匹配项"
        echo "$result"
    else
        echo_color red "${hostname}: 未找到匹配项"
    fi
}

# 解析 StarRocks BE 节点的崩溃和启动时间
function parse_starrocks_times() {
    local hostname="$1"
   # 获取BE路径
    local be_path=$(sshcheck "$hostname" "ps -ef | grep starrocks_be | grep -v grep | grep -v gdb | sed 's/\/lib.*//' | head -n 1")
    be_path=$(echo "$be_path" | awk '{print $NF}')
    if [ -z "$be_path" ]; then
        echo_color red "无法确定BE路径"
        return 1
    fi
    local log_path="${be_path}/log/be.out"
    # 获取最近一次崩溃时间
    local last_crash_timestamp=$(sshcheck "$hostname" "grep -a -o 'Aborted at [0-9]*' \"$log_path\" | tail -1 | awk '{print \$3}'")
    # 获取最近一次启动时间
    local last_start_time=$(sshcheck "$hostname" "grep -a  'start time: ' \"$log_path\" | tail -1")
    # 检查是否找到崩溃时间
    if [ -z "$last_crash_timestamp" ]; then
        echo "未找到崩溃时间信息"
    else
        # 转换时间戳为可读格式
        local crash_time=$(sshcheck "$hostname" "date -d \"@$last_crash_timestamp\" +\"%Y-%m-%d %H:%M:%S\"")
    fi
    # 检查是否找到启动时间
    if [ -z "$last_start_time" ]; then
        echo "未找到启动时间信息"
    else
            # 手动解析时间字符串
            local ampm=$(echo $last_start_time | awk '{print $7}')
            local time=$(echo $last_start_time | awk '{print $6}')

            
            # 转换12小时制为24小时制
            local hour=$(echo $time | cut -d: -f1)
            local min=$(echo $time | cut -d: -f2)
            local sec=$(echo $time | cut -d: -f3)
            
            if [ "$ampm" = "PM" ] && [ "$hour" -lt 12 ]; then
                hour=$((10#$hour + 12))
            elif [ "$ampm" = "AM" ] && [ "$hour" -eq 12 ]; then
                hour="00"
            fi

            # 重建标准格式
            start_time="${hour}:${min}:${sec}"
    fi
    echo ${hostname} ${crash_time} ${start_time}
    return 0
}

# 显示帮助信息
function show_help() {
    echo "用法: $0 [选项] <节点列表文件>"
    echo "选项:"
    echo "  -c          更改 core 打印开关"
    echo "  -l <模式>   搜索BE日志，指定搜索模式（默认: bc4df468-3fae-11f0-8d8f-58a2e1a95f4c）"
    echo "  -a          添加配置到BE"
    echo "  -t          解析BE崩溃和启动时间"
    echo "  -h          显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0 -c nodes.txt                  # 更改所有节点的 core 打印开关"
    echo "  $0 -l 'ERROR' nodes.txt          # 搜索所有节点BE日志中的'ERROR'"
    echo "  $0 -l nodes.txt                  # 使用默认模式搜索BE日志"
    echo "  $0 -a 'new_config' nodes.txt  # 向所有节点添加新配置"
    echo "  $0 -t nodes.txt                # 解析所有节点BE崩溃和启动时间"
}

# 主函数：根据参数对节点执行指定操作
function changeByPid() {
    local action=$1
    local param=$2
    local node_file=$3
    
    # 检查节点列表文件是否存在
    if [ ! -f "$node_file" ]; then
        echo_color red "错误: 文件 $node_file 不存在!"
        exit 1
    fi
    
    # 读取节点列表
    local node_list=$(cat "$node_file")
    
    # 如果使用逗号分隔符，则进行处理
    if [[ -n $(echo "$node_list" | grep ',') ]]; then
        node_list=${node_list//,/ }
    fi
    
    # 对每个节点执行指定操作
    for hostname in $node_list; do
        echo
        
        # 检查节点连接
        if ! check_node_connection "$hostname"; then
            continue
        fi
        
        # 根据选择的操作执行相应的函数
        case "$action" in
            "change_core_set")
                change_core_set "$hostname"
                ;;
            "grep_be_log")
                grep_be_log "$hostname" "$param"
                ;;
            "addConf2BEs")
                if [ -z "$param" ]; then
                    echo_color red "ERROR: NO configuration"
                    exit 1
                fi
                addConf2BEs "$hostname" "$param"
                ;;
            "parse_starrocks_times")
                parse_starrocks_times "$hostname"
                ;;
            *)
                echo_color red "ERROR: UNknown ERROR"
                exit 1
                ;;
        esac
    done
}

# 解析命令行参数
action=""
param=""
file=""

while getopts "cl:a:p:th" opt; do
    case $opt in
        c)
            action="change_core_set"
            ;;
        l)
            action="grep_be_log"
            param="$OPTARG"
            ;;
        a)
            action="addConf2BEs"
            param="$OPTARG"
            ;;
        t)
            action="parse_starrocks_times"
            ;;
        h)
            show_help
            exit 0
            ;;
        \?)
            echo "无效选项: -$OPTARG" >&2
            show_help
            exit 1
            ;;
        :)
            echo "选项 -$OPTARG 需要参数" >&2
            show_help
            exit 1
            ;;
    esac
done

# 获取节点列表文件
shift $((OPTIND-1))
file="$1"

# 验证参数
if [ -z "$action" ]; then
    echo_color red "错误: 必须指定操作选项 (-c, -l, -a.-t)"
    show_help
    exit 1
fi

if [ -z "$file" ]; then
    echo_color red "错误: 必须指定节点列表文件"
    show_help
    exit 1
fi

# 执行主函数，明确传递所有参数
changeByPid "$action" "$param" "$file"

exit 0