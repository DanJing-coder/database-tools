#!/bin/bash

# StarRocks BE 升级/备份/回滚工具 (优化版)
# 用法: ./be_upgrade_tool.sh [-m mode] [-d dir] [-f file] [-v version] <hosts_file>

set -u # 遇到未定义变量报错，但不设置 -e 以便手动处理错误

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
log_step() { echo -e "${CYAN}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# 默认变量
MODE=""             # backup | upload | rollback
TARGET_DIR="lib"    # 默认操作目录
SOURCE_FILE=""      # upload 模式源路径
VERSION_SUFFIX=$(date '+%m%d') # 默认版本后缀

usage() {
    echo "用法: $0 -m <mode> [-d <dir>] [-f <file>] [-v <suffix>] <hosts_file>"
    echo "选项:"
    echo "  -m <mode>    模式: backup (备份), upload (全量替换), rollback (回滚)"
    echo "  -d <dir>     远程目标目录名 (默认: lib)"
    echo "  -f <file>    [upload模式必填] 本地源文件或目录路径"
    echo "  -v <suffix>  版本后缀 (默认: 当前月日 $VERSION_SUFFIX)"
    echo "  <hosts_file> 包含BE IP的文本文件"
    exit 1
}

while getopts "hm:d:f:v:" opt; do
    case $opt in
        h) usage ;;
        m) MODE="$OPTARG" ;;
        d) TARGET_DIR="$OPTARG" ;;
        f) SOURCE_FILE="$OPTARG" ;;
        v) VERSION_SUFFIX="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ $# -ne 1 ] || [ -z "$MODE" ]; then
    log_error "缺少必要参数"
    usage
fi

HOSTS_FILE="$1"
[ ! -f "$HOSTS_FILE" ] && { log_error "Hosts文件不存在: $HOSTS_FILE"; exit 1; }

# ---------------------------------------------------------
# 核心逻辑
# ---------------------------------------------------------
process_node() {
    local ip=$1
    log_step "开始处理节点: $ip [模式: $MODE]"

    # 1. 获取远程 BE 目录路径 (依赖 BE 进程存在)
    # 注意：如果 BE 已停止，此步骤会失败。建议在 BE 运行时执行 upload，然后重启。
    local remote_be_home
    remote_be_home=$(ssh -o ConnectTimeout=5 "$ip" "ps -ef | grep starrocks_be | grep -v grep | grep -v gdb | sed 's/\/lib.*//' | awk '{print \$NF}' | head -n 1" 2>/dev/null || echo "")

    if [ -z "$remote_be_home" ]; then
        log_error "节点 $ip: 无法定位 starrocks_be 进程。请确保 BE 正在运行以定位路径。"
        return 1
    fi
    log_info "节点 $ip: BE_HOME = $remote_be_home"

    case "$MODE" in
        backup)
            # ---------------------------
            # 备份模式
            # ---------------------------
            local backup_name="${TARGET_DIR}_${VERSION_SUFFIX}"
            log_info "节点 $ip: 执行备份 $TARGET_DIR -> $backup_name"
            ssh "$ip" "cd $remote_be_home && \
                       if [ -d $TARGET_DIR ]; then \
                           cp -r $TARGET_DIR $backup_name && echo 'OK'; \
                       else \
                           echo 'Target not found'; exit 1; \
                       fi"
            if [ $? -eq 0 ]; then
                log_info "节点 $ip: 备份成功"
            else
                log_error "节点 $ip: 备份失败"
            fi
            ;;
        
        upload)
            # ---------------------------
            # 上传模式 (全量替换)
            # ---------------------------
            if [ -z "$SOURCE_FILE" ]; then log_error "上传模式需指定 -f 参数"; exit 1; fi
            if [ ! -e "$SOURCE_FILE" ]; then log_error "本地源文件不存在: $SOURCE_FILE"; exit 1; fi

            # 定义变量
            # 去除源路径末尾的斜杠，保证 scp 行为一致
            local clean_source="${SOURCE_FILE%/}" 
            # 远程临时上传目录
            local tmp_upload_dir="${TARGET_DIR}_tmp_new_$(date +%s)"
            # 替换下来的旧版本由于不是显式备份，命名为 replaced 用于应急
            local auto_backup="${TARGET_DIR}_replaced_$(date +%s)"

            log_info "节点 $ip: [Step 1/3] 上传新文件到临时目录: $tmp_upload_dir"
            
            # 先确保远程临时目录不存在
            ssh "$ip" "rm -rf $remote_be_home/$tmp_upload_dir"
            
            # 上传
            scp -r "$clean_source" "$ip":"$remote_be_home/$tmp_upload_dir"
            if [ $? -ne 0 ]; then
                log_error "节点 $ip: SCP 上传失败，停止操作"
                return 1
            fi

            log_info "节点 $ip: [Step 2/3] 上传完成，正在执行原子替换..."

            # 原子替换逻辑：
            # 1. 进入目录
            # 2. 将现有 lib 移走 (mv lib lib_replaced_xxx) - 这一步不会导致 BE 崩溃，但重启前旧进程还在用旧文件
            # 3. 将新上传的临时目录改名为 lib (mv lib_tmp_new lib)
            ssh "$ip" "cd $remote_be_home && \
                       [ -d $TARGET_DIR ] && mv $TARGET_DIR $auto_backup; \
                       mv $tmp_upload_dir $TARGET_DIR"

            if [ $? -eq 0 ]; then
                log_info "节点 $ip: [Step 3/3] 替换成功！"
                log_info "节点 $ip: 原目录已自动移至: $auto_backup (非 -m backup 生成的备份)"
                log_warn "节点 $ip: *** 请务必重启 BE 进程以加载新文件 ***"
            else
                log_error "节点 $ip: 目录替换操作失败，请手动检查服务器！"
                return 1
            fi
            ;;

        rollback)
            # ---------------------------
            # 回滚模式
            # ---------------------------
            local backup_name="${TARGET_DIR}_${VERSION_SUFFIX}"
            log_info "节点 $ip: 尝试回滚版本 $backup_name -> $TARGET_DIR"
            
            ssh "$ip" "cd $remote_be_home && \
                if [ -d $backup_name ]; then \
                    # 将当前错误的 lib 移走，防止重名冲突
                    [ -d $TARGET_DIR ] && mv $TARGET_DIR ${TARGET_DIR}_rollback_trash_$(date +%s); \
                    # 恢复指定的备份
                    cp -r $backup_name $TARGET_DIR; \
                    echo 'Rollback success'; \
                else \
                    echo 'Backup version not found'; exit 1; \
                fi"
                
            if [ $? -eq 0 ]; then
                log_info "节点 $ip: 回滚成功，请重启 BE"
            else
                log_error "节点 $ip: 回滚失败，找不到备份文件 $backup_name"
            fi
            ;;
        *)
            log_error "未知模式: $MODE"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------
# 主循环
# ---------------------------------------------------------
log_info "任务开始..."
while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    IFS=',' read -ra IPS <<< "$line"
    for ip in "${IPS[@]}"; do
        ip=$(echo "$ip" | xargs)
        [ -z "$ip" ] && continue
        process_node "$ip"
    done
done < "$HOSTS_FILE"

log_info "所有任务执行完毕。"