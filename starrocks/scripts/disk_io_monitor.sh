#!/bin/bash

# disk_io_monitor.sh
# 监控磁盘读写(R/W)和延迟(Latency)统计
# 修复版：已替换高负载的 lsof 命令为轻量级 /proc 分析

# 输出颜色设置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
LOG_FILE="/var/log/disk_io_monitor.log"
PID_FILE="/var/run/disk_io_monitor.pid"
INTERVAL=5  # 采样间隔（秒）
TOP_PROCESSES=20  # 显示的进程数量

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 需要 root 权限才能运行${NC}"
        exit 1
    fi
}

# 检查依赖工具
check_dependencies() {
    local missing=()
    
    command -v iostat >/dev/null 2>&1 || missing+=("sysstat")
    command -v pidstat >/dev/null 2>&1 || missing+=("sysstat")
    # lsof 已移除，不再作为强依赖，但保留检查
    # command -v lsof >/dev/null 2>&1 || missing+=("lsof")
    command -v blktrace >/dev/null 2>&1 || missing+=("blktrace")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}警告: 缺少以下软件包，脚本可能无法完整运行: ${missing[*]}${NC}"
        echo -e "${YELLOW}请手动安装: dnf install -y ${missing[*]}${NC}"
        # 建议不要在脚本里自动安装，避免锁死 yum
    fi
}

# 获取磁盘统计信息
get_disk_stats() {
    echo "============================== $(date '+%a %b %d - %H:%M:%S') =============================="
    
    # 1. 总体磁盘统计
    echo -e "\n${BLUE}=== 总体磁盘统计 (iostat) ===${NC}"
    iostat -dxm $INTERVAL 2 | tail -n +7
    
    # 2. 磁盘 IO 最高的 Top 进程
    echo -e "\n${BLUE}=== 磁盘 IO Top-$TOP_PROCESSES 进程 ===${NC}"
    
    # 使用 pidstat 获取 IO 统计
    pidstat -dl $INTERVAL 1 2>/dev/null | \
        awk 'NR>3 && $9+$10 > 0 {print $0}' | \
        sort -k10 -rn | \
        head -n $TOP_PROCESSES | \
        while read line; do
            pid=$(echo $line | awk '{print $4}')
            user=$(echo $line | awk '{print $2}')
            # 获取进程名，处理可能退出的情况
            comm=$(ps -p $pid -o comm= 2>/dev/null || echo "N/A")
            
            # [优化关键点] 替换 lsof -p $pid
            # 直接查看 /proc/$pid/fd 下的链接，速度极快，不会卡死 CPU
            if [ -d "/proc/$pid/fd" ]; then
                files=$(ls -l /proc/$pid/fd/ 2>/dev/null | awk -F'-> ' '{print $2}' | grep -E '\.(dat|log|db|data|wal)$' | head -3 | tr '\n' ';')
            else
                files="Process_Exited"
            fi
            
            # 读写量统计
            read_kb=$(echo $line | awk '{print $6}')
            write_kb=$(echo $line | awk '{print $7}')
            
            # 转换为人类可读格式 (M/K)
            if (( $(echo "$read_kb > 1024" | bc -l) )); then
                read_human=$(echo "scale=1; $read_kb/1024" | bc)M
            else
                read_human="${read_kb}K"
            fi
            
            if (( $(echo "$write_kb > 1024" | bc -l) )); then
                write_human=$(echo "scale=1; $write_kb/1024" | bc)M
            else
                write_human="${write_kb}K"
            fi
            
            # 判断主要是读还是写
            if (( $(echo "$read_kb > $write_kb" | bc -l) )); then
                op_type="READ"
                percentage=$(echo "scale=0; 100*$read_kb/($read_kb+$write_kb+1)" | bc)
                op_size="$read_human"
            else
                op_type="WRITE"
                percentage=$(echo "scale=0; 100*$write_kb/($read_kb+$write_kb+1)" | bc)
                op_size="$write_human"
            fi
            
            # 输出格式化日志
            echo "$(date '+%a %b %d - %H:%M:%S'),$pid,$comm,$user,$op_type,$op_size,${percentage}%,$files"
        done
    
    # 3. 延迟(Latency)统计
    echo -e "\n${BLUE}=== 延迟统计 (Latency) ===${NC}"
    
    # 如果有 blkparse 工具则执行
    if command -v blkparse >/dev/null 2>&1; then
        echo "正在采集延迟数据 (1秒采样)..."
        # 这里的 timeout 1 比较安全
        timeout 1 blktrace -d /dev/sda -o - 2>/dev/null | \
            blkparse -i - -f "%T:%t %p %d %S %n\n" | \
            grep -E "(Q|C)" | \
            awk '
            BEGIN {count=0; total=0}
            /Q/ {start[$6]=$2}
            /C/ && start[$6] {latency=($2-start[$6]); total+=latency; count++}
            END {if(count>0) printf("平均延迟: %.2f ms\n", (total/count)*1000)}'
    else
        echo "未找到 blktrace/blkparse 工具，跳过延迟分析。"
    fi
    
    # 4. 用户 IO 统计
    echo -e "\n${BLUE}=== 用户 IO 统计 ===${NC}"
    pidstat -dl $INTERVAL 1 2>/dev/null | \
        awk 'NR>3 && $9+$10 > 0 {user[$2]+=$9+$10} 
        END {for (u in user) printf("用户: %-15s IOPS: %-10.2f\n", u, user[u])}' | \
        sort -k4 -rn
    
    # 5. 文件描述符统计
    echo -e "\n${BLUE}=== 文件描述符占用 Top 10 ===${NC}"
    # [优化关键点] 替换原来的全局 lsof
    # 原来的命令会扫描全系统，导致高负载。这里改为较轻量的统计方式，或者仅统计特定目录
    # 这里为了性能，我们通过扫描 /proc 来实现类似功能，虽然稍微复杂点但快得多
    
    # 注意：在 Bash 中完全模拟 lsof 的全局统计比较复杂且也耗时。
    # 建议直接简化为查看谁打开的文件句柄最多：
    find /proc/*/fd -type l -printf "%l\n" 2>/dev/null | \
        grep -E '\.(dat|log|db|data)$' | \
        awk -F'/' '{print $NF}' | \
        sort | uniq -c | sort -rn | head -10 | \
        awk '{print "打开次数: " $1 " 文件: " $2}'
}

# 实时监控主循环
monitor_realtime() {
    echo -e "${GREEN}启动磁盘 IO 监控...${NC}"
    echo -e "${YELLOW}采样间隔: ${INTERVAL} 秒${NC}"
    echo -e "${YELLOW}停止监控请按: Ctrl+C${NC}\n"
    
    # 捕获退出信号
    trap "cleanup; exit 0" SIGINT SIGTERM
    
    while true; do
        get_disk_stats | tee -a "$LOG_FILE"
        echo ""
        sleep $INTERVAL
    done
}

# 退出清理
cleanup() {
    echo -e "\n${YELLOW}正在停止监控...${NC}"
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
}

# 启动服务
start_service() {
    check_root
    check_dependencies
    
    if [[ -f "$PID_FILE" ]]; then
        # 检查 PID 是否真的存在
        if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo -e "${YELLOW}服务已经在运行中${NC}"
            exit 1
        else
            echo -e "${YELLOW}发现残留 PID 文件，但在运行进程中未找到，将重新启动。${NC}"
        fi
    fi
    
    echo $$ > "$PID_FILE"
    echo -e "${GREEN}监控服务已启动${NC}"
    echo -e "日志文件: $LOG_FILE"
    echo -e "PID: $$"
    
    monitor_realtime
}

# 查看日志
show_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${RED}未找到日志文件${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}=== 最新日志记录 ===${NC}"
    tail -f "$LOG_FILE" | grep -E "$(date '+%a %b %d')"
}

# 生成报告
generate_report() {
    echo -e "${BLUE}=== 今日汇总报告 ===${NC}"
    
    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${RED}未找到日志文件${NC}"
        exit 1
    fi
    
    # 活跃进程 Top
    echo -e "\n${GREEN}磁盘 IO 最活跃的进程:${NC}"
    grep -E '^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} -' "$LOG_FILE" | \
        awk -F',' '{process[$3]++} 
        END {for (p in process) print p ": " process[p] " 条记录"}' | \
        sort -k2 -rn | head -10
    
    # 活跃用户 Top
    echo -e "\n${GREEN}最活跃的用户:${NC}"
    grep -E '^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} -' "$LOG_FILE" | \
        awk -F',' '{user[$4]++} 
        END {for (u in user) print u ": " user[u] " 次操作"}' | \
        sort -k2 -rn | head -10
    
    # 操作类型统计
    echo -e "\n${GREEN}读写操作类型统计:${NC}"
    grep -E '^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} -' "$LOG_FILE" | \
        awk -F',' '{ops[$5]++} 
        END {for (o in ops) print o ": " ops[o] " 条记录"}' | \
        sort -k2 -rn
}

# 显示帮助
show_help() {
    echo "用法: $0 [命令]"
    echo ""
    echo "命令列表:"
    echo "  start     - 启动实时监控"
    echo "  stop      - 停止监控服务"
    echo "  status    - 查看服务状态"
    echo "  logs      - 实时查看日志"
    echo "  report    - 生成今日汇总报告"
    echo "  help      - 显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 start          # 启动"
    echo "  $0 logs           # 看日志"
    echo "  $0 report         # 看报告"
}

# 主逻辑入口
case "${1}" in
    start)
        start_service
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            PID=$(cat "$PID_FILE")
            if kill -0 $PID 2>/dev/null; then
                kill $PID
                rm -f "$PID_FILE"
                echo -e "${GREEN}服务已停止${NC}"
            else
                echo -e "${YELLOW}PID 文件存在但进程不存在，正在清理...${NC}"
                rm -f "$PID_FILE"
            fi
        else
            echo -e "${YELLOW}服务未运行${NC}"
        fi
        ;;
    status)
        if [[ -f "$PID_FILE" ]] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo -e "${GREEN}服务正在运行${NC}"
            ps -p $(cat "$PID_FILE") -o pid,user,cmd
        else
            echo -e "${RED}服务未运行${NC}"
        fi
        ;;
    logs)
        show_logs
        ;;
    report)
        generate_report
        ;;
    help|*)
        show_help
        ;;
esac