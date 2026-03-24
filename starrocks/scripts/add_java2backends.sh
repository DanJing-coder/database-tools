    #!/bin/bash

    # 脚本功能是批量在StarRocks BE节点的start_backend.sh中插入JAVA_HOME环境变量配置到第二行，支持单个节点或多个节点（通过文件或逗号分隔）。脚本会检查节点免密连接和BE安装路径的有效性，并提供彩色输出提示。

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
            echo_color red "${1} 节点免密未打通，跳过处理"
            return 1
        fi
        return 0
    }

    # 获取BE安装路径
    function get_be_path() {
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

    # 在start_be.sh中追加JAVA_HOME配置
    function add_java_home() {
        local hostname=$1
        local exe_user=$(whoami)
        
        # 获取BE安装路径
        local be_path=$(get_be_path "$hostname")
        if [ -z "$be_path" ]; then
            echo_color red "无法获取 ${hostname} 的BE安装路径，请检查进程是否运行"
            return 1
        fi
        
        # 定义start_be.sh路径
        local start_be_path="${be_path}/bin/start_backend.sh"
        
        # 检查start_be.sh文件是否存在
        local file_exists=$(ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
            "[ -f '${start_be_path}' ] && echo 'exists' || echo 'not exists'" 2>/dev/null)
        if [ "$file_exists" != "exists" ]; then
            echo_color red "${hostname} 的start_be.sh文件不存在: ${start_be_path}"
            return 1
        fi
        
        # 插入JAVA_HOME配置到第二行（#!/usr/bin/env bash之后）
        local java_home_config="export JAVA_HOME=/home/starrocks/jdk-17"
        ssh -o ConnectTimeout=5 "${exe_user}@${hostname}" \
            "awk -v jh='${java_home_config}' 'NR==1{print; print jh; next} 1' '${start_be_path}' > '${start_be_path}.tmp' && mv '${start_be_path}.tmp' '${start_be_path}'" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo_color green "已成功在 ${hostname} 的 ${start_be_path} 中插入JAVA_HOME配置到第二行"
            return 0
        else
            echo_color red "在 ${hostname} 的 ${start_be_path} 中插入JAVA_HOME配置失败"
            return 1
        fi
    }

    # 显示帮助信息
    function show_help() {
        echo "用法: $0 <目标>"
        echo "功能: 在指定节点的BE的/start_backend.sh 中插入JAVA_HOME配置到第二行"
        echo "参数说明:"
        echo "  <目标>        节点列表文件（每行一个节点或用逗号分隔的节点）或单个节点主机名/IP"
        echo "示例:"
        echo "  $0 be_nodes.txt    # 处理所有节点"
        echo "  $0 node1           # 处理单个节点"
        echo "  $0 192.168.1.100  # 处理单个IP节点"
        exit 1
    }

    # 主函数：解析参数并批量执行
    function main() {
        # 解析选项
        if [ $# -ne 1 ]; then
            show_help
        fi
        local target=$1
        
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
                        node_list+=($node)
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
            node_list=($target)
            echo_color blue "目标节点: ${target}"
        fi
        
        # 对每个节点执行操作
        for node in "${node_list[@]}"; do
            if [ -z "$node" ]; then
                continue  # 跳过空行
            fi
            if check_node_connection "$node"; then
                add_java_home "$node"
            else
                echo_color red "跳过无法连接的节点: ${node}\n"
            fi
        done
    }

    # 启动主程序
    main "$@"