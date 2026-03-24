#!/bin/bash

# 彩色输出函数
echo_color() {
    case "$1" in
        "green")  echo -e "\033[32;40m$2\033[0m" ;;  # 绿色
        "red")    echo -e "\033[31;40m$2\033[0m" ;;  # 红色
        "yellow") echo -e "\033[33;40m$2\033[0m" ;;  # 黄色
        "blue")   echo -e "\033[34;40m$2\033[0m" ;;  # 蓝色
        *)        echo "$2" ;;                        # 默认颜色
    esac
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项] <配置文件路径> <配置项=值>"
    echo ""
    echo "功能: 修改配置文件，支持备份、更新/新增配置项"
    echo ""
    echo "选项:"
    echo "  -h, --help      显示帮助信息"
    echo "  -s, --sudo      使用sudo权限执行"
    echo ""
    echo "示例:"
    echo "  $0 /etc/sysctl.conf vm.min_free_kbytes=10485760"
    echo "  $0 -s /etc/security/limits.conf nofile=65535"
    echo ""
    exit 1
}

# 参数解析
use_sudo=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -s|--sudo)
            use_sudo=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

# 检查必要参数
if [[ $# -ne 2 ]]; then
    echo_color red "错误: 参数不足"
    show_help
fi

# 获取配置文件路径和配置项
config_file="$1"
config_item="$2"

# 检查配置项格式（必须包含等号）
if [[ "$config_item" != *"="* ]]; then
    echo_color red "错误: 配置项格式不正确，请使用'key=value'格式"
    exit 1
fi

# 解析配置项的键和值
config_key=$(echo "$config_item" | awk -F"=" '{print $1}' | sed 's/[[:space:]]*$//')
config_value=$(echo "$config_item" | awk -F"=" '{print substr($0, index($0, "=")+1)}' | sed 's/^[[:space:]]*//')

# 显示配置信息
echo_color blue "配置文件: $config_file"
echo_color blue "配置项: $config_key"
echo_color blue "配置值: $config_value"
echo_color blue "是否使用sudo: $use_sudo"

# 检查配置文件是否存在
if ! $use_sudo && [ ! -f "$config_file" ]; then
    echo_color red "错误: 配置文件 '$config_file' 不存在，且未指定sudo权限"
    exit 1
elif $use_sudo && ! sudo [ -f "$config_file" ]; then
    echo_color red "错误: 使用sudo权限也无法访问配置文件 '$config_file'"
    exit 1
fi

# 备份配置文件
echo_color blue "开始备份配置文件..."
backup_date=$(date +%m%d)
backup_file="${config_file}_${backup_date}"

if $use_sudo; then
    if sudo cp "$config_file" "$backup_file"; then
        echo_color green "成功备份配置文件到: $backup_file"
    else
        echo_color red "备份配置文件失败"
        exit 1
    fi
else
    if cp "$config_file" "$backup_file"; then
        echo_color green "成功备份配置文件到: $backup_file"
    else
        echo_color red "备份配置文件失败"
        exit 1
    fi
fi

# 修改配置项
echo_color blue "开始修改配置项..."

# 构建sed命令，处理等号两边可能的空格
# 查找模式：配置键后面跟着可选空格、等号、可选空格、任意内容
# 替换为：配置键=配置值
# 使用-i.bak参数创建临时备份文件，确保操作安全
sed_command="s/^[[:space:]]*${config_key}[[:space:]]*=[[:space:]]*.*/${config_key}=${config_value}/"

# 检查配置文件中是否存在该配置项
if $use_sudo; then
    # 使用sudo检查配置项是否存在
    if sudo grep -q "^[[:space:]]*${config_key}[[:space:]]*=[[:space:]]*" "$config_file"; then
        # 存在则更新
        echo_color blue "配置项 '$config_key' 已存在，将更新其值"
        if sudo sed -i "$sed_command" "$config_file"; then
            echo_color green "成功更新配置项: ${config_key}=${config_value}"
        else
            echo_color red "更新配置项失败"
            exit 1
        fi
    else
        # 不存在则新增
        echo_color blue "配置项 '$config_key' 不存在，将在文件末尾新增"
        if sudo echo "${config_key}=${config_value}" >> "$config_file"; then
            echo_color green "成功新增配置项: ${config_key}=${config_value}"
        else
            echo_color red "新增配置项失败"
            exit 1
        fi
    fi
else
    # 不使用sudo检查配置项是否存在
    if grep -q "^[[:space:]]*${config_key}[[:space:]]*=[[:space:]]*" "$config_file"; then
        # 存在则更新
        echo_color blue "配置项 '$config_key' 已存在，将更新其值"
        if sed -i "$sed_command" "$config_file"; then
            echo_color green "成功更新配置项: ${config_key}=${config_value}"
        else
            echo_color red "更新配置项失败"
            exit 1
        fi
    else
        # 不存在则新增
        echo_color blue "配置项 '$config_key' 不存在，将在文件末尾新增"
        if echo "${config_key}=${config_value}" >> "$config_file"; then
            echo_color green "成功新增配置项: ${config_key}=${config_value}"
        else
            echo_color red "新增配置项失败"
            exit 1
        fi
    fi
fi

# 显示完成信息
echo_color blue "配置修改完成！"
