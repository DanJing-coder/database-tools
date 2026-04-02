#!/bin/bash

# 脚本功能批量开启关闭be节点的核心转储设置，支持单个节点或多个节点（通过文件或逗号分隔）。当开启核心转储时，可以选择性地指定core文件输出路径，默认路径为 /mnt/dump/%h_%e_%p.core。脚本会检查节点免密连接和BE安装路径的有效性，并提供彩色输出提示。

# 当前执行脚本的用户
exe_user=$(whoami)

# green:通过 red:未通过 blue:需修改配置 yellow: 标题
function echo_color() {
    case "$1" in
        "green")  echo -e "\033[32;40m$2\033[0m" ;;
        "red")    echo -e "\033[31;40m$2\033[0m" ;;
        "yellow") echo -e "\033[33;40m$2\033[0m" ;;
        "blue")   echo -e "\033[34;40m$2\033[0m" ;;
        *)        echo "$2" ;;
    esac
}

# 到其他节点执行命令并返回结果
function sshcheck() {
    ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 "${exe_user}@${1}" "${2}" 2>/dev/null
}

# 到其他节点执行命令不返回结果(用于更新操作)
function sshUpdate() {
    ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 "${exe_user}@${1}" "${2}" >/dev/null 2>&1
}

# 检查节点连接状态
function check_node_connection() {
    if ! sshcheck "$1" "pwd" &>/dev/null; then
        echo_color red "${1} 节点免密未打通"
        return 1
    fi
    return 0
}

# --- 新增: 通用BE路径获取函数 ---
# 逻辑: 1. 优先通过运行中的进程获取(/proc/PID/exe) 2. 兜底通过 find 查找安装目录
function get_be_home() {
    local hostname=$1
    sshcheck "$hostname" "bash -c '
        be_path=\"\"
        # 1. 尝试通过运行中的进程精准定位 (使用 pgrep -x 避开 vmtouch/gdb)
        be_pid=\$(pgrep -x starrocks_be | head -n 1)
        
        if [ -n \"\$be_pid\" ]; then
            # 通过内核符号链接获取绝对路径 (Result: .../lib/starrocks_be)
            exe_path=\$(readlink -f /proc/\$be_pid/exe 2>/dev/null)
            if [ -n \"\$exe_path\" ]; then
                # 回退两层目录: /lib/starrocks_be -> /lib -> BE_HOME
                be_path=\$(dirname \$(dirname \"\$exe_path\"))
            fi
        fi

        # 2. 如果进程未运行，尝试查找安装目录
        if [ -z \"\$be_path\" ]; then
            # 查找 /starrocks 目录下的 be-* 文件夹
            be_dirs=()
            while IFS= read -r -d \"\" dir; do
                be_dirs+=(\"\$dir\")
            done < <(find /starrocks -maxdepth 1 -type d -name \"be-*\" -print0 2>/dev/null | head -z -n 5)

            if [ \${#be_dirs[@]} -gt 0 ]; then
                # 对目录按修改时间排序，取最新的
                latest_be_dir=\"\"
                for dir in \"\${be_dirs[@]}\"; do
                    if [ -z \"\$latest_be_dir\" ] || [ \"\$dir\" -nt \"\$latest_be_dir\" ]; then
                        latest_be_dir=\"\$dir\"
                    fi
                done
                be_path=\"\$latest_be_dir\"
            fi
        fi
        echo \"\$be_path\"
    '"
}

# 重新检查核心转储设置
function recheck() {
    local hostname=$1
    local pid=$2
    
    echo_color yellow "检查 ${hostname} 节点的核心转储设置:"
    
    # 如果pid不为空,检查进程限制
    if [ -n "$pid" ]; then
        echo_color blue "当前进程限制:" 
        sshcheck "$hostname" "cat /proc/$pid/limits | grep \"Max core file size\" | grep -v grep | awk '{print \"Soft Limit:\" \$5, \"Hard Limit:\" \$6}'"
    else
        echo_color blue "当前进程限制: 未找到进程，跳过检查"
    fi
    
    echo_color blue "limits.conf 设置:" 
    sshcheck "$hostname" 'grep "^.*soft.*core" /etc/security/limits.conf | grep -v \#' | tr -d '*'
    sshcheck "$hostname" 'grep "^.*hard.*core" /etc/security/limits.conf | grep -v \#' | tr -d '*'
    
    echo_color blue "Core文件输出路径设置:"
    sshcheck "$hostname" "cat /proc/sys/kernel/core_pattern 2>/dev/null || echo \"未设置\""
}

# 设置core文件路径
function set_core_path() {
    local hostname=$1
    local core_path=$2
    
    # 设置默认core文件输出路径
    local default_core_path="/mnt/dump/%h_%e_%p.core"
    local final_core_path=${core_path:-$default_core_path}
    
    # 提取目录部分
    local core_dir=$(dirname "$final_core_path")
    core_dir=${core_dir/\%h/*}
    core_dir=${core_dir/\%e/*}
    core_dir=${core_dir/\%p/*}
    
    # 检查core文件输出目录是否存在
    echo_color blue "正在检查core文件输出目录 ${core_dir}..."
    local dir_exists=$(sshcheck "$hostname" "ls -d ${core_dir} 2>/dev/null || echo 'not_exist'")
    if [ "$dir_exists" = "not_exist" ]; then
        echo_color red "错误: core文件输出目录 ${core_dir} 不存在。请手动创建该目录后再启用核心转储功能。"
        return 1
    fi
    
    # 设置core文件输出路径(需要sudo权限)
    echo_color blue "正在设置core文件输出路径为 ${final_core_path}..."
    sshUpdate "$hostname" "echo -n '${final_core_path}' | sudo tee /proc/sys/kernel/core_pattern >/dev/null"
    return $?
}

# 更改核心转储设置
function change_core_set() {
    local hostname=$1
    local mode=$2
    local core_path=$3
    
    # 默认模式为关闭
    if [ -z "$mode" ]; then
        mode="off"
    fi
    
    # 验证模式参数
    if [[ "$mode" != "on" && "$mode" != "off" ]]; then
        echo_color red "错误: 无效的模式参数 '$mode',请使用 'on' 或 'off'"
        return 1
    fi
    
    # 根据模式设置core值
    local core_value=""
    if [ "$mode" = "on" ]; then
        core_value="unlimited"
        echo_color yellow "正在 ${hostname} 节点开启核心转储设置(值: unlimited)..."
        
        # 设置core文件路径
        if ! set_core_path "$hostname" "$core_path"; then
            return 1
        fi
    else
        core_value="0"
        echo_color yellow "正在 ${hostname} 节点关闭核心转储设置(值: 0)..."
    fi
    
    # --- 优化 PID 获取逻辑 ---
    # 1. 优先使用 pgrep -x 获取 starrocks_be 的 PID (最准确)
    local be_pid=$(sshcheck "$hostname" "pgrep -x starrocks_be | head -n 1")
    local super_pid=""

    # 2. 如果找到了 BE 进程，通过 ps 获取其父进程 (通常是 supervisor 或 start 脚本)
    if [ -n "$be_pid" ]; then
        super_pid=$(sshcheck "$hostname" "ps -o ppid= -p $be_pid | tr -d ' '")
    else
        # 3. 如果没找到 starrocks_be，尝试找 start_be.sh (使用 pgrep -f 避免 grep grep)
        # 注意：pgrep -f 匹配全命令行，比 grep 更安全
        be_pid=$(sshcheck "$hostname" "pgrep -f '/bin/start_be.sh' | head -n 1")
        if [ -n "$be_pid" ]; then
            super_pid=$(sshcheck "$hostname" "ps -o ppid= -p $be_pid | tr -d ' '")
        fi
    fi
    # --- 优化结束 ---
    
    # 如果找到进程,修改进程粒度的参数
    if [ -n "$be_pid" ]; then
        # 动态修改BE进程和supervisor进程的core输出限制(需要sudo权限)
        sshUpdate "$hostname" "sudo prlimit -p ${be_pid} --core=${core_value}"
        if [ -n "$super_pid" ] && [ "$super_pid" -ne 0 ] && [ "$super_pid" -ne 1 ]; then
            sshUpdate "$hostname" "sudo prlimit -p ${super_pid} --core=${core_value}"
        fi
        # 验证修改结果
        echo_color blue "验证进程(${be_pid})core限制修改结果:" 
        sshcheck "$hostname" "cat /proc/${be_pid}/limits | grep 'Max core file size'"
    else
        echo_color yellow "未找到BE进程或start_be.sh进程，跳过进程粒度的参数修改"
    fi
    
    # 备份并修改配置文件
    sshUpdate "$hostname" 'sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak'
    
    if [[ -z $(sshcheck "$hostname" 'grep "^.*soft.*core" /etc/security/limits.conf') ]]; then
        sshUpdate "$hostname" "echo '* soft core ${core_value}' | sudo tee -a /etc/security/limits.conf"
    else
        if [ "$mode" = "on" ]; then
            sshUpdate "$hostname" 'sudo sed -i "/soft.*core/s/0/unlimited/" /etc/security/limits.conf'
        else
            sshUpdate "$hostname" 'sudo sed -i "/soft.*core/s/unlimited/0/" /etc/security/limits.conf'
        fi
    fi
    
    if [[ -z $(sshcheck "$hostname" 'grep "^.*hard.*core" /etc/security/limits.conf') ]]; then
        sshUpdate "$hostname" "echo '* hard core ${core_value}' | sudo tee -a /etc/security/limits.conf"
    else
        if [ "$mode" = "on" ]; then
            sshUpdate "$hostname" 'sudo sed -i "/hard.*core/s/0/unlimited/" /etc/security/limits.conf'
        else
            sshUpdate "$hostname" 'sudo sed -i "/hard.*core/s/unlimited/0/" /etc/security/limits.conf'
        fi
    fi
    
    # 检查配置
    recheck "$hostname" "$be_pid"
}

# 向be.conf中增加配置
function addConf2BEs() {
    local hostname=$1
    local config=$2
    
    echo_color yellow "正在向 ${hostname} 节点的be.conf添加配置..."
    
    # --- 优化路径获取逻辑 ---
    local be_path=$(get_be_home "$hostname")
    
    if [ -z "$be_path" ]; then
        echo_color red "无法确定BE路径 (未运行且未找到 /starrocks/be-*)"
        return 1
    fi
    
    local conf_path="${be_path}/conf/be.conf"
    # --- 优化结束 ---

    local backup_path="${conf_path}_$(date +%Y%m%d)"  # 备份文件名格式: be.conf_20250606
    
    # 创建备份
    echo_color blue "正在备份原始配置文件..."
    if ! sshUpdate "$hostname" "sudo cp -f ${conf_path} ${backup_path}"; then
        echo_color red "备份失败,取消操作"
        return 1
    fi
    echo_color green "配置文件已备份至: ${backup_path}"
    
    # 添加配置
    echo_color blue "正在添加新配置..."
    if ! sshUpdate "$hostname" "echo '${config}' | sudo tee -a ${conf_path}"; then
        echo_color red "配置添加失败,尝试恢复原文件"
        sshUpdate "$hostname" "sudo cp -f ${backup_path} ${conf_path}"
        return 1
    fi
    
    # 验证配置是否添加成功
    echo_color blue "正在验证配置..."
    if sshcheck "$hostname" "grep -q '${config}' ${conf_path}"; then
        echo_color green "配置已成功添加到 ${conf_path}"
    else
        echo_color red "配置验证失败,恢复原文件"
        sshUpdate "$hostname" "sudo cp -f ${backup_path} ${conf_path}"
        return 1
    fi
}

# 搜索BE日志 - 支持传入搜索参数
function grep_be_log() {
    local hostname=$1
    local search_pattern=$2
    
    # 如果未提供搜索模式,使用默认值
    if [ -z "$search_pattern" ]; then
        search_pattern="bc4df468-3fae-11f0-8d8f-58a2e1a95f4c"
    fi
    
    echo_color yellow "正在搜索 ${hostname} 节点的BE日志(模式: ${search_pattern})..."
    
    # --- 优化路径获取逻辑 ---
    local be_path=$(get_be_home "$hostname")
    
    if [ -z "$be_path" ]; then
        echo_color red "无法确定BE路径 (未运行且未找到 /starrocks/be-*)"
        return 1
    fi
    
    local log_path="${be_path}/log/be.out"
    # --- 优化结束 ---
    
    # 搜索日志
    local result=$(sshcheck "$hostname" "grep -a '${search_pattern}' ${log_path}")
    
    if [ -n "$result" ]; then
        echo_color green "${hostname}: 找到匹配项"
        echo "$result"
    else
        echo_color red "${hostname}: 未找到匹配项"
    fi
}

# 显示帮助信息
function show_help() {
    echo "用法: $0 [选项] [参数] [core路径] <节点列表文件>"
    echo "选项:" 
    echo "  -c [on|off]  更改核心转储设置,可选参数 on(开启,值为unlimited) 或 off(关闭,值为0),默认为off"
    echo "  -p [路径]    设置core文件输出路径,默认路径为 /mnt/dump/%h_%e_%p.core"
    echo "  -l <模式>    搜索BE日志,指定搜索模式(默认: bc4df468-3fae-11f0-8d8f-58a2e1a95f4c)"
    echo "  -a <配置>    添加配置到BE"
    echo "  -h           显示此帮助信息"
    echo
    echo "当使用 -c on 选项时,可以选择性地指定core文件输出路径,默认路径为 /mnt/dump/%h_%e_%p.core"
    echo "%h: 主机名, %e: 程序名, %p: 进程ID"
    echo
    echo "示例:" 
    echo "  $0 -c nodes.txt                  # 关闭所有节点的核心转储设置(默认)"
    echo "  $0 -c on nodes.txt               # 开启所有节点的核心转储设置,使用默认路径"
    echo "  $0 -c off nodes.txt              # 关闭所有节点的核心转储设置(值为0)"
    echo "  $0 -c on /custom/path/%h_%e_%p.core nodes.txt  # 开启核心转储并指定自定义路径"
    echo "  $0 -p /custom/path/%h_%e_%p.core nodes.txt  # 仅设置core文件输出路径"
    echo "  $0 -l 'ERROR' nodes.txt          # 搜索所有节点BE日志中的'ERROR'"
    echo "  $0 -l nodes.txt                  # 使用默认模式搜索BE日志"
    echo "  $0 -a 'new_config' nodes.txt     # 向所有节点添加新配置"
}

# 主函数：根据参数对节点执行指定操作
function changeByPid() {
    local action=$1
    local param=$2
    local node_file=$3
    local custom_core_path=$4
    
    # 检查节点列表文件是否存在
    if [ ! -f "$node_file" ]; then
        echo_color red "错误: 文件 $node_file 不存在!"
        exit 1
    fi
    
    # 读取节点列表
    local node_list=$(cat "$node_file")
    
    # 如果使用逗号分隔符,则进行处理
    if [[ -n $(echo "$node_list" | grep ',') ]]; then
        node_list=${node_list//,/ }
    fi
    
    # 对每个节点执行指定操作
    for hostname in $node_list; do
        echo
        echo_color yellow "******************************************************************************************"
        echo_color yellow "处理 $hostname 节点"
        echo_color yellow "******************************************************************************************"
        
        # 检查节点连接
        if ! check_node_connection "$hostname"; then
            continue
        fi
        
        # 根据选择的操作执行相应的函数
        case "$action" in
            "change_core_set")
                change_core_set "$hostname" "$param" "$custom_core_path"
                ;;
            "set_core_path")
                set_core_path "$hostname" "$custom_core_path"
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
custom_core_path=""

# 定义短选项
while getopts "cl:a:p:h" opt; do
    case $opt in
        c)
            action="change_core_set"
            ;;
        p)
            action="set_core_path"
            custom_core_path="$OPTARG"
            ;;
        l)
            action="grep_be_log"
            param="$OPTARG"
            ;;
        a)
            action="addConf2BEs"
            param="$OPTARG"
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

# 处理选项后的可选参数
shift $((OPTIND-1))
if [ "$action" = "change_core_set" ]; then
    if [[ -n "$1" && ("$1" = "on" || "$1" = "off") ]]; then
        param="$1"
        shift
        # 只有在开启核心转储时才检查自定义core路径
        if [ "$param" = "on" ] && [ -n "$1" ]; then
            custom_core_path="$1"
            shift
        fi
    fi
fi

# 获取节点列表文件
file="$1"

# 验证参数
if [ -z "$action" ]; then
    echo_color red "错误: 必须指定操作选项 (-c, -l, -a)"
    show_help
    exit 1
fi

if [ -z "$file" ]; then
    echo_color red "错误: 必须指定节点列表文件"
    show_help
    exit 1
fi


# 执行主函数,明确传递所有参数
changeByPid "$action" "$param" "$file" "$custom_core_path"

exit 0