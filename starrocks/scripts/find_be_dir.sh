#!/bin/bash

# ==============================================================================
# 脚本名称: find_be_dir.sh
# 功能: 在 BE 节点的 /data1~/data24 目录下搜索包含指定字符串的目录
# 用法: ./find_be_dir.sh <be_hosts文件> <搜索字符串> [SSH用户]
# 示例: ./find_be_dir.sh ./be_hosts.txt 12345678
#        ./find_be_dir.sh ./be_hosts.txt 12345678 alex
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_result() { echo -e "${CYAN}[RESULT]${NC} $1"; }

# 显示用法
usage() {
    echo "用法: $0 <be_hosts文件> <搜索字符串> [SSH用户]"
    echo ""
    echo "参数说明:"
    echo "  be_hosts文件  包含BE节点IP地址的文本文件"
    echo "               支持格式: 逗号分隔、空格分隔、换行分隔"
    echo "  搜索字符串    要搜索的目录名包含的字符串 (如 12345678)"
    echo "  SSH用户      可选，默认使用当前用户 $(whoami)"
    echo ""
    echo "示例:"
    echo "  # 换行分隔 (每行一个IP)"
    echo "  10.0.0.1"
    echo "  10.0.0.2"
    echo "  10.0.0.3"
    echo ""
    echo "  # 逗号分隔"
    echo "  10.0.0.1, 10.0.0.2, 10.0.0.3"
    echo ""
    echo "  # 空格分隔"
    echo "  10.0.0.1 10.0.0.2 10.0.0.3"
    echo ""
    echo "  $0 ./be_hosts.txt 12345678"
    echo "  $0 ./be_hosts.txt 12345678 alex"
    exit 1
}

# 检查参数
if [ "$#" -lt 2 ]; then
    log_error "参数不足"
    usage
fi

HOSTS_FILE="$1"
SEARCH_STR="$2"
SSH_USER="${3:-$(whoami)}"

# 检查 hosts 文件是否存在
if [ ! -f "$HOSTS_FILE" ]; then
    log_error "hosts文件不存在: $HOSTS_FILE"
    exit 1
fi

log_info "开始搜索 BE 节点"
log_info "  hosts文件: $HOSTS_FILE"
log_info "  搜索字符串: $SEARCH_STR"
log_info "  SSH用户: $SSH_USER"
echo "------------------------------------------"

# 解析 IP 文件（支持逗号、空格、换行分隔）
# tr 将逗号和空格替换为换行，sed 去除可能的首尾空格和空行
IPS=$(cat "$HOSTS_FILE" | tr ', \t' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v '^$')

# 统计变量
TOTAL_HOSTS=0
FOUND_COUNT=0

# 逐个处理每个 IP
for BE_IP in $IPS; do
    # 跳过注释行
    if [[ "$BE_IP" =~ ^# ]]; then
        continue
    fi

    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
    log_info "正在检查节点: $BE_IP"

    # SSH 到 BE 节点搜索 /data1~/data24 目录
    # 使用 find 命令搜索包含 SEARCH_STR 的目录，找到第一个就停止
    RESULT=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${SSH_USER}@${BE_IP}" "
        for i in \$(seq 1 24); do
            DATA_DIR=\"/data\$i\"
            if [ -d \"\$DATA_DIR\" ]; then
                # 搜索包含指定字符串的目录，-maxdepth 5 覆盖常见的多层目录结构
                FOUND_DIR=\$(find \"\$DATA_DIR\" -maxdepth 5 -type d -name '*${SEARCH_STR}*' 2>/dev/null | head -n 1)
                if [ -n \"\$FOUND_DIR\" ]; then
                    echo \"\$FOUND_DIR\"
                    exit 0
                fi
            fi
        done
    " 2>/dev/null) || {
        log_warn "SSH 连接失败: $BE_IP"
        continue
    }

    if [ -n "$RESULT" ]; then
        FOUND_COUNT=$((FOUND_COUNT + 1))
        log_result "节点: $BE_IP"
        log_result "路径: $RESULT"
        echo "------------------------------------------"
    else
        log_info "节点 $BE_IP: 未找到"
    fi

done

echo "=========================================="
log_info "搜索完成"
log_info "总计检查节点: $TOTAL_HOSTS"
log_info "找到匹配: $FOUND_COUNT"
echo "=========================================="
