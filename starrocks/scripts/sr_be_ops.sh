#!/bin/bash

# ==============================================================================
# 脚本名称: sr_be_ops.sh
# 功能描述: StarRocks BE 节点批量配置管理与日志检索工具
# 核心逻辑: 动态定位BE路径 -> 切换目录 -> 执行相对路径文件的增删改查
# ==============================================================================

# --- 基础配置 ---
SSH_TIMEOUT=5
COLOR_GREEN="\033[32m"
COLOR_RED="\033[31m"
COLOR_YELLOW="\033[33m"
COLOR_RESET="\033[0m"

function log_info() { echo -e "${COLOR_GREEN}[INFO] $1${COLOR_RESET}"; }
function log_warn() { echo -e "${COLOR_YELLOW}[WARN] $1${COLOR_RESET}"; }
function log_err() { echo -e "${COLOR_RED}[ERROR] $1${COLOR_RESET}"; }

# --- 核心函数：动态获取BE路径 (基于优化版) ---
function get_be_path() {
    local hostname=$1
    local exe_user=$(whoami)
    
    # 1. 排除 vmtouch/tail 等干扰
    # 2. 精确匹配第8列以 starrocks_be 结尾的进程
    # 3. 截取 BE_HOME
    local be_path=$(ssh -o ConnectTimeout=${SSH_TIMEOUT} "${exe_user}@${hostname}" \
        "ps -ef | grep 'starrocks_be' | grep -v grep | grep -v 'vmtouch' | awk '\$8 ~ /starrocks_be$/ {print \$8}' | head -n 1 | sed 's/\/lib\/starrocks_be.*//'" 2>/dev/null)
    
    echo "$be_path" | tr -d '\r' | xargs
}

# --- 远程执行动作函数 ---
function perform_action() {
    local node=$1
    local rel_file=$2    # 相对路径，如 conf/be.conf
    local action=$3      # search, upsert, comment
    local content=$4     # 搜索内容 或 修改内容
    local exe_user=$(whoami)

    echo "--------------------------------------------------"
    log_info "正在处理节点: ${node}"

    # 1. 获取 BE Home
    local be_home=$(get_be_path "$node")
    if [ -z "$be_home" ]; then
        log_err "未找到运行中的 BE 进程，跳过。"
        return
    fi
    # log_info "定位 BE_HOME: ${be_home}"

    # 2. 构建远程命令块
    # 使用 Base64 编码内容以防止特殊字符(引号/空格)在 SSH 传输中导致语法错误
    local content_b64=$(echo -n "$content" | base64 | tr -d '\n')
    
    # 远程脚本逻辑
    ssh -o ConnectTimeout=${SSH_TIMEOUT} "${exe_user}@${node}" "bash -s" <<EOF
    # 切换到 BE 根目录，这样相对路径就能生效
    cd "${be_home}" || exit 1
    
    target_file="${rel_file}"
    
    # 检查文件是否存在
    if [ ! -f "\$target_file" ]; then
        echo -e "${COLOR_RED}[Remote] 文件不存在: \$(realpath -m "\$target_file" 2>/dev/null || echo "\$target_file")${COLOR_RESET}"
        exit 1
    fi
    
    abs_path=\$(readlink -f "\$target_file")
    decoded_content=\$(echo "${content_b64}" | base64 -d)

    case "${action}" in
        "search")
            echo -e "${COLOR_GREEN}[搜索结果] \$abs_path:${COLOR_RESET}"
            # grep 显示行号，忽略大小写
            grep -n -i "\$decoded_content" "\$target_file" --color=always || echo "未找到匹配项"
            ;;

        "upsert")
            # 1. 备份
            cp "\$target_file" "\$target_file.bak.\$(date +%Y%m%d_%H%M%S)"
            
            # 2. 判断是 Key-Value 修改还是纯追加
            # 检查是否包含 '='
            if [[ "\$decoded_content" == *"="* ]]; then
                key=\$(echo "\$decoded_content" | cut -d'=' -f1 | tr -d '[:space:]')
                
                # 检查文件中是否存在该配置项 (行首匹配)
                if grep -q "^[[:space:]]*\$key[[:space:]]*=" "\$target_file"; then
                    # 存在：使用 sed 替换整行
                    # 注意：这里使用了 | 作为分隔符，如果内容包含 | 会报错，但在配置中很少见
                    sed -i "s|^[[:space:]]*\$key[[:space:]]*=.*|\$decoded_content|g" "\$target_file"
                    echo -e "${COLOR_GREEN}[修改成功] 已更新配置项: \$key${COLOR_RESET}"
                else
                    # 不存在：追加到文件末尾
                    # 确保文件最后一行有换行符，防止拼接在同一行
                    sed -i -e '\$a\' "\$target_file"
                    echo "\$decoded_content" >> "\$target_file"
                    echo -e "${COLOR_GREEN}[追加成功] 已新增配置项: \$key${COLOR_RESET}"
                fi
            else
                # 没有等号，直接追加（适用于脚本或非KV配置）
                sed -i -e '\$a\' "\$target_file"
                echo "\$decoded_content" >> "\$target_file"
                echo -e "${COLOR_GREEN}[追加成功] 已追加内容${COLOR_RESET}"
            fi
            
            # 验证修改
            tail -n 1 "\$target_file"
            ;;

        "comment")
            # 1. 备份
            cp "\$target_file" "\$target_file.bak.\$(date +%Y%m%d_%H%M%S)"
            
            # 2. 注释匹配行
            # 仅注释未被注释的行
            if grep -q "^\s*\$decoded_content" "\$target_file"; then
                sed -i "/^\s*\$decoded_content/s/^/#/" "\$target_file"
                echo -e "${COLOR_GREEN}[注释成功] 已注释包含 '\$decoded_content' 的行${COLOR_RESET}"
            else
                echo -e "${COLOR_YELLOW}[跳过] 未找到以 '\$decoded_content' 开头的有效行${COLOR_RESET}"
            fi
            ;;
    esac
EOF
}

# --- 帮助与参数解析 ---
function show_help() {
    echo "用法: $0 -f <相对路径> [操作选项] -n <节点列表/IP>"
    echo ""
    echo "参数:"
    echo "  -f <path>    目标文件相对路径 (相对于 BE 安装目录)"
    echo "               示例: 'conf/be.conf', '../log/be.INFO', 'bin/start_be.sh'"
    echo "  -n <nodes>   节点列表文件 或 单个IP (必填)"
    echo ""
    echo "操作 (互斥，选其一):"
    echo "  -s <text>    [Search] 搜索文本 (支持grep正则)"
    echo "  -u <text>    [Upsert] 修改或追加配置"
    echo "               - 如果是 'Key=Value' 且Key存在 -> 替换"
    echo "               - 否则 -> 追加到末尾"
    echo "  -c <text>    [Comment] 注释掉以该文本开头的行"
    echo ""
    echo "示例:"
    echo "  1. 检索日志报错:"
    echo "     $0 -f '../log/be.INFO' -s 'Disk error' -n 192.168.1.100"
    echo "  2. 修改或添加配置 (自动备份):"
    echo "     $0 -f 'conf/be.conf' -u 'sys_log_level = INFO' -n node_list.txt"
    echo "  3. 注释掉某个配置:"
    echo "     $0 -f 'conf/be.conf' -c 'enable_bitmap_union_disk_format_with_set' -n 10.0.0.1"
    exit 1
}

# --- 主逻辑 ---
target_file=""
action=""
content=""
node_input=""

while getopts ":f:s:u:c:n:h" opt; do
    case $opt in
        f) target_file="$OPTARG" ;;
        s) action="search"; content="$OPTARG" ;;
        u) action="upsert"; content="$OPTARG" ;;
        c) action="comment"; content="$OPTARG" ;;
        n) node_input="$OPTARG" ;;
        h) show_help ;;
        *) echo "无效参数: -$OPTARG"; show_help ;;
    esac
done

# 参数校验
if [ -z "$target_file" ] || [ -z "$node_input" ] || [ -z "$action" ]; then
    echo -e "${COLOR_RED}错误: 必须指定文件路径(-f)、操作类型(-s/-u/-c) 和 节点(-n)${COLOR_RESET}"
    show_help
fi

# 解析节点列表
node_list=()
if [ -f "$node_input" ]; then
    # 处理文件输入 (兼容逗号和换行)
    file_content=$(cat "$node_input")
    if [[ "$file_content" == *","* ]]; then
        IFS=',' read -ra nodes <<< "$file_content"
        node_list=("${nodes[@]}")
    else
        while IFS= read -r line; do
            [[ -n "$line" && ! "$line" =~ ^# ]] && node_list+=("$line")
        done < "$node_input"
    fi
else
    node_list=("$node_input")
fi

# 批量执行
for node in "${node_list[@]}"; do
    # 去除空格
    node=$(echo "$node" | xargs)
    if [ -n "$node" ]; then
        perform_action "$node" "$target_file" "$action" "$content"
    fi
done