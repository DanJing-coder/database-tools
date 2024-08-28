#!/bin/bash

# ip,默认本地
host=127.0.0.1
# 端口,默认9030
port=9030
# 数据库用户名,默认root
sr_user=root
# 数据库密码
sr_password=""
#当前执行脚本的用户
exe_user=$(whoami)
# 执行操作
opt_flag=""

if [[ $1 = "--help" ]]; then
    #输出使用信息
    echo "----------------------------------------------------------------------------------------------"
    echo "| 注   意： 请到 manager 部署节点执行该脚本                                                  |"
    echo "----------------------------------------------------------------------------------------------"
    echo "| 输入参数：                                                                                 |"
    echo "----------------------------------------------------------------------------------------------"
    echo "|   -h 指定SR集群节点IP      |  默认: 127.0.0.1                                   |  非必输  |"
    echo "|   -P 指定SR集群Query 端口  |  默认: 9030                                        |  非必输  |"
    echo "|   -u SR 集群用户名         |  默认: root                                        |  非必输  |"
    echo "|   -p 指定 SR 集群密码      |  默认为空,为空时请勿添加该参数                     |  非必输  |"
    echo "----------------------------------------------------------------------------------------------"
    echo "|   -o 修改集群节点系统配置  |  默认为空,为空时仅查看参数，                       |  非必输  |"
    echo "|                            |  指定 update 更新系统指标                          |          |"
    echo "----------------------------------------------------------------------------------------------"
    echo "|   -l 指定操作的节点        |  默认为空,为空时连接 SR 获取集群                   |  非必输  |"
    echo "|                            |  节点信息,节点间用空格或逗号分隔,                  |          |"
    echo "|                            |  修改指定节点配置示例，去掉-o参数可以查看节点配置：|          |"
    echo "|                            |  ./env_check.sh -l \"10.0.0.1 10.0.0.2\" -oupdate    |          |"
    echo "----------------------------------------------------------------------------------------------"
    echo "| 输出信息:                                                                                  |"
    echo "----------------------------------------------------------------------------------------------"
    echo "|   绿色:通过  红色:未通过  蓝色:需修改配置文件,否则重启失效  黄色：标题                     |"
    echo "----------------------------------------------------------------------------------------------"
    exit 0
fi

while getopts ":h:P:u:p:o:l:" opt; do
    case "$opt" in
    h)
        # 赋值ip
        host="$OPTARG"
        ;;
    P)
        # 赋值sr集群query端口
        port="${OPTARG}"
        ;;
    u)
        # 赋值用户
        sr_user="${OPTARG}"
        ;;
    p)
        # 赋值密码
        sr_password="${OPTARG}"
        ;;
    o)
        # 进行的操作，update执行更新操作
        opt_flag="${OPTARG}"
        ;;
    l)
        # 节点列表
        node_list="${OPTARG}"
        ;;
    ?)
        echo "未知参数"
        exit 1
        ;;
    esac
done

# green:通过 red:未通过 blue:需修改配置 yellow: 标题
function echo_color() {
    if [ $1 == "green" ]; then
        echo -e "\033[32;40m$2\033[0m"
    elif [ $1 == "red" ]; then
        echo -e "\033[31;40m$2\033[0m"
    elif [ $1 == "yellow" ]; then
        echo -e "\033[33;40m$2\033[0m"
    elif [ $1 == "blue" ]; then
        echo -e "\033[34;40m$2\033[0m"
    fi
}

# 输出表格
function echo_table() {
    # 设置列分隔符和表格边界符
    delimiter=","
    border=""
    line="-"
    # 将文本转换为整齐的表格
    table=$(echo -e "$*" | column -s "$delimiter" -t -o " | ")

    # 添加列分割线
    separator=$(echo "$table" | head -n 1 | sed 's/[^|]/-/g')
    output=$(echo "$table" | sed "1s/^/$border/; 2s/|$/$border/; s/|$/$border/")

    # 添加行分割线
    # lines=$(echo "$output" | wc -l)
    # line_separator=$(printf "%-${#separator}s" "$line" | tr " " "$line")
    # final_output=$(echo "$output" | awk -v l="$lines" -v s="$line_separator" 'NR == 2 {print s} {print}')

    # 输出表格
    echo "$output"
}

# 如果使用逗号分隔符，则进行处理
if [[ -n $(echo $node_list | grep ',') ]]; then
    node_list=${node_list//,/ }
fi

if [[ ! -n $node_list ]]; then
    # 增加逻辑判断
    if [[ -n $sr_password ]]; then
        checkBeIpCol=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show backends;" 2>/dev/null | awk 'NR==2{print $2}' 2>/dev/null)
    else
        checkBeIpCol=$(mysql -h ${host} -u ${sr_user} -P ${port} -e "show backends;" | awk 'NR==2{print $2}')
    fi

    # be 所在列,默认取第二列
    if [[ $checkBeIpCol == "default_cluster" ]]; then
        if [[ -n $sr_password ]]; then
            feIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show frontends;" 2>/dev/null | awk 'NR!=1{print $2}')
            beIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show backends;" 2>/dev/null | awk 'NR!=1{print $3}')
        else
            feIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -e "show frontends;" | awk 'NR!=1{print $2}')
            beIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -e "show backends;" | awk 'NR!=1{print $3}')
        fi
    else
        if [[ -n $sr_password ]]; then
            feIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show frontends;" 2>/dev/null | awk 'NR!=1{print $2}')
            beIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show backends;" 2>/dev/null | awk 'NR!=1{print $2}')
        else
            feIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -e "show frontends;" | awk 'NR!=1{print $2}')
            beIps=$(mysql -h ${host} -u ${sr_user} -P ${port} -e "show backends;" | awk 'NR!=1{print $2}')
        fi
    fi
    # 如果根据输入的集群信息没有查询到结果，提示用户检查
    if [[ -z $feIps && -z $beIps ]]; then
        echo_color yellow "未查询到节点信息,请检查输入的参数 IP,用户,端口,密码信息是否正确!"
        exit 1
    fi
fi

# 到其他节点执行命令
function sshcheck() {
    echo -e $(ssh ${exe_user}@${1} ${2})
}

# 到其他节点执行更新
function sshUpdate() {
    ssh ${exe_user}@${1} ${2}
}

## 检查各个节点的 SWAPPINESS 是否关闭
function check_swap() {
    if [[ "0" = $(sshcheck $1 "cat /proc/sys/vm/swappiness | grep ^0$") && (-n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.swappiness=0$"') || -n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.swappiness = 0$"')) ]]; then
        echo_color green "swp check pass"
    elif [[ "0" = $(sshcheck $1 "cat /proc/sys/vm/swappiness | grep ^0$") && !(-n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.swappiness=0$"') || -n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.swappiness = 0$"')) ]]; then
        echo_color blue "/etc/sysctl.conf"
    else
        echo_color red "$(sshcheck $1 "cat /proc/sys/vm/swappiness")"
    fi
}

# 检查文件打开数
function check_ulimitn() {
    ulimitnNum=$(sshcheck $1 "ulimit -n")
    if [[ "65535" -le $ulimitnNum ]]; then
        echo_color green "ulimit -n: $ulimitnNum"
    else
        echo_color red "ulimit -n: $ulimitnNum"
    fi
    # if [[ -n $(cat /etc/security/limits.conf | grep -w "^soft nofile 65536$") && -n $(cat /etc/security/limits.conf | grep -w"^hard nofile 65536$") ]]; then
    #   NUM_LIMIT=1
    # else
    #   NUM_LIMIT=2
    # fi

    # if [[ (-n $(cat /etc/sysctl.conf | grep "^vm.max_map_count=655360$") || -n $(cat /etc/sysctl.conf | grep "vm.max_map_count = 655360$")) ]]; then
    #   NUM_LIMIT=1
    # else
    #   NUM_LIMIT=2
    # fi
}

# 检查 JAVA_HOME 以及 JDK 版本
function jdk_check() {
    if [ -z $(sshcheck $1 'source /etc/profile && echo $JAVA_HOME') ]; then
        echo_color red "JAVA_HOME not set"
    else
        jdk_version=$(sshcheck $1 'source /etc/profile && echo $JAVA_HOME')
        echo_color green ${jdk_version##*/}
    fi

}

# 检查 overcommit
function check_overcommit() {
    if [[ "1" = $(sshcheck $1 "cat /proc/sys/vm/overcommit_memory" | grep "^1$") && (-n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.overcommit_memory=1$"') || -n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.overcommit_memory = 1$"')) ]]; then
        echo_color green "ome check pass"
    elif [[ "1" = $(sshcheck $1 "cat /proc/sys/vm/overcommit_memory" | grep "^1$") && !(-n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.overcommit_memory=1$"') || -n $(sshcheck $1 'cat /etc/sysctl.conf | grep "^vm.overcommit_memory = 1$"')) ]]; then
        echo_color blue "/etc/sysctl.conf "
    else
        echo_color red "$(sshcheck $1 "cat /proc/sys/vm/overcommit_memory")"
    fi
}

## 检查 cpu
function cpu_check() {
    if [[ -n $(sshcheck $1 "cat /proc/cpuinfo" | grep "avx2") ]]; then
        echo_color green "$(sshcheck $1 "cat /proc/cpuinfo | grep -c processor") vcpu"
    else
        echo_color red "cpu not support avx2"
    fi
}

# 检查最大进程数
function check_ulimitu() {
    ulimituNum=$(sshcheck $1 "ulimit -u")
    if [[ "65535" -le $ulimituNum ]]; then
        echo_color green "ulimit -u: $ulimituNum"
    else
        echo_color red "ulimit -u: $ulimituNum"
    fi
    # if [[ -n $(cat /etc/security/limits.conf | grep -w "^soft nofile 65536$") && -n $(cat /etc/security/limits.conf | grep -w"^hard nofile 65536$") ]]; then
    #   NUM_LIMIT=1
    # else
    #   NUM_LIMIT=2
    # fi

    # if [[ (-n $(cat /etc/sysctl.conf | grep "^vm.max_map_count=655360$") || -n $(cat /etc/sysctl.conf | grep "vm.max_map_count = 655360$")) ]]; then
    #   NUM_LIMIT=1
    # else
    #   NUM_LIMIT=2
    # fi
}

## 检查 Huge Pages 这个会干扰内存分配器，导致性能下降。
function hugepage_check() {
    if [[ -n $(sshcheck $1 "cat /sys/kernel/mm/transparent_hugepage/enabled | grep '\[madvise\]'") ]]; then
        echo_color green "$(sshcheck $1 "cat /sys/kernel/mm/transparent_hugepage/enabled")"
    else
        echo_color red "$(sshcheck $1 "cat /sys/kernel/mm/transparent_hugepage/enabled")"
    fi
}

## 检查 somaxconn socket监听(listen)的backlog上限
function check_somaxconn() {
    if [[ 1024 -le $(sshcheck $1 "cat /proc/sys/net/core/somaxconn") && (-n $(sshcheck $1 'cat /etc/sysctl.conf | grep -E "^net.core.somaxconn=[0-9]{4,}$"')) ]]; then
        echo_color green "som check pass"
    elif [[ 1024 -le $(sshcheck $1 "cat /proc/sys/net/core/somaxconn") && !(-n $(sshcheck $1 'cat /etc/sysctl.conf | grep -E "^net.core.somaxconn=[0-9]{4,}$"')) ]]; then
        echo_color blue "check somaxconn in /etc/sysctl.conf"
    else
        echo_color red "$(sshcheck $1 "cat /proc/sys/net/core/somaxconn")"
    fi
}

# 检查 tcp_abort_on_overflow 期望值为1
# 0 ：如果 accept 队列满了，那么 server 扔掉 client 发过来的 ack ；
# 1 ：如果 accept 队列满了，server 发送一个 RST 包给 client，表示废掉这个握手过程和这个连接；
function check_tcp_overflow() {
    if [[ "1" = $(sshcheck $1 "cat /proc/sys/net/ipv4/tcp_abort_on_overflow") ]]; then
        echo_color green "tcp check pass"
    else
        echo_color red "$(sshcheck $1 "cat /proc/sys/net/ipv4/tcp_abort_on_overflow")"
    fi
}

# 检查时钟同步
function check_clock() {
    echo " $(sshcheck $1 "date +'%Y-%m-%d %H:%M:%S'") "
}

# check SELINUX setenforce 0
check_selinux() {
    if [[ "Disabled" = $(sshcheck $1 "$(which getenforce)") && (-n $(sshcheck $1 'grep -i "^SELINUX=disabled" /etc/selinux/config')) ]]; then
        echo_color green "selinux check pass"
    elif [[ "Disabled" = $(sshcheck $1 "$(which getenforce)") && !(-n $(sshcheck $1 'grep -i "^SELINUX=disabled" /etc/selinux/config')) ]]; then
        echo_color blue "check /etc/sysctl.conf "
    else
        echo_color red "$(sshcheck $1 "$(which getenforce)")"
    fi
}

# check FE 进程连接最大进程数
check_FE_pid_ulimitu() {
    pid=$(sshcheck $1 "ps -ef | grep com.starrocks.StarRocksFE |grep -v grep| awk -F\" \" '{print \$2}'  |head -n 1")
    result=$(sshcheck $1 "cat /proc/$pid/limits | grep \"Max processes\" |grep -v grep| awk '{print \"Soft Limit:\"\$3,\"Hard Limit:\"\$4}'")
    echo $result
}

# check FE 进程文件打开数
check_FE_pid_ulimitn() {
    pid=$(sshcheck $1 "ps -ef | grep com.starrocks.StarRocksFE |grep -v grep| awk -F\" \" '{print \$2}'  |head -n 1")
    result=$(sshcheck $1 "cat /proc/$pid/limits | grep \"Max open files\" |grep -v grep| awk '{print \"Soft Limit:\"\$4,\"Hard Limit:\"\$5}'")
    echo $result
}

# check BE 进程连接最大进程数
check_BE_pid_ulimitu() {
    pid=$(sshcheck $1 "ps -ef | grep /bin/start_be.sh |grep -v grep| awk -F\" \" '{print \$2}'  |head -n 1")
    result=$(sshcheck $1 "cat /proc/$pid/limits | grep \"Max processes\" |grep -v grep| awk '{print \"Soft Limit:\"\$3,\"Hard Limit:\"\$4}'")
    echo $result
}

# check BE 进程文件打开数
check_BE_pid_ulimitn() {
    pid=$(sshcheck $1 "ps -ef  | grep /bin/start_be.sh |grep -v grep| awk -F\" \" '{print \$2}'  |head -n 1")
    result=$(sshcheck $1 "cat /proc/$pid/limits | grep \"Max open files\" |grep -v grep| awk '{print \"Soft Limit:\"\$4,\"Hard Limit:\"\$5}'")
    echo $result
}

# FE节点检查 JVM 配置的大小 ps -ef |grep "com.starrocks.StarRocksFE" |grep -v grep| awk '{for(i=1;i<=NF;i++) if ($i ~ /-Xmx[0-9]*m/) print $i}'
check_Xmx() {
    xmx=$(sshcheck $1 "ps -ef | grep "com.starrocks.StarRocksFE"|grep -v grep| awk '{for(i=1;i<=NF;i++) if (\$i ~ /-Xmx[0-9]*m/) print \$i}'|head -n 1 ")
    echo_color green "$xmx"
}

# 检查节点的内存
check_sys_mem() {
    sys_mem=$(sshcheck $1 "free -h | awk 'NR==2{print \"total:\"\$2,\"used:\"\$3}' ")
    echo_color green "$sys_mem"
}

# 检查OOM
check_oom_error() {
    if [[ -z $(sshcheck $1 'dmesg -T|grep "Out of memory: Kill process" | grep "starrocks"') ]]; then
        echo_color green "No OOM"
    else
        echo_color red "OOM has occurred!"
    fi
}

# 检查是否有内存故障
check_mem_error() {
    if [[ -z $(sshcheck $1 'dmesg -T|grep -i "DRAM ECC error detected"') ]]; then
        echo_color green "No memory fault"
    else
        echo_color red "Need to check mem"
    fi
}

# 检查磁盘属性
check_disk_prop() {
    hdd_num=$(sshcheck $1 " lsblk -d -o name,rota | grep -c '1$'")
    ssd_num=$(sshcheck $1 " lsblk -d -o name,rota | grep -c '0$'")
    sum_disk=$((hdd_num + ssd_num))
    echo_color green "sum_disk:$sum_disk hdd_num:$hdd_num ssd_num:$ssd_num"
}

# 检查 be 节点磁盘剩余可用
# TODO

# 检查进程可以拥有的VMA(虚拟内存区域)的数量
function check_max_map_count() {
    if [[ 262144 -le $(sshcheck $1 "$(which sysctl) -a 2>/dev/null|grep -w 'vm.max_map_count'"|awk -F '[= ]+' '{print $2}') && (-n $(sshcheck $1 'cat /etc/sysctl.conf | grep -E "^vm.max_map_count=[0-9]{6,}$"')) ]]; then
        echo_color green "max_map_count check pass"
    elif [[ 262144 -le $(sshcheck $1 "$(which sysctl) -a 2>/dev/null|grep -w 'vm.max_map_count'"|awk -F '[= ]+' '{print $2}') && !(-n $(sshcheck $1 'cat /etc/sysctl.conf | grep -E "^vm.max_map_count=[0-9]{6,}$"')) ]]; then
        echo_color blue "check max_map_count in /etc/sysctl.conf"
    else
        echo_color red "$(sshcheck $1 "$(which sysctl) -a2 >/dev/null|grep -w 'vm.max_map_count'")"
    fi
}

# 增加系统参数检查
function checkVariables() {
    sr_version=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "select current_version();" 2>/dev/null | awk 'NR==2{print $1}' 2>/dev/null)
    enable_pipeline=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show variables like 'enable_pipeline_engine';" 2>/dev/null | awk 'NR==2{print $2}' 2>/dev/null)
    dop=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show variables like 'pipeline_dop';" 2>/dev/null | awk 'NR==2{print $2}' 2>/dev/null)
    para=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show variables like 'parallel_fragment_exec_instance_num';" 2>/dev/null | awk 'NR==2{print $2}' 2>/dev/null)
    release_version="2.5.0"
    # 比较版本号
    if [[ $(echo -e "$sr_version\n$release_version" | sort -V | tail -n1) == $sr_version ]]; then
        enable_profile=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show variables like '%enable_profile%';" 2>/dev/null | awk 'NR==2{print $2}' 2>/dev/null)
    else
        enable_profile=$(mysql -h ${host} -u ${sr_user} -P ${port} -p${sr_password} -e "show variables like '%is_report_success%';" 2>/dev/null | awk 'NR==2{print $2}' 2>/dev/null)
    fi
    echo_color yellow "系统参数检查:"
    echo_color green "starrocks version: $sr_version "
    echo_color green "enable_pipeline_engine: $enable_pipeline "
    echo_color green "pipeline_dop: $dop "
    echo_color green "parallel_fragment_exec_instance_num: $para "
    echo_color green "enable_profile: $enable_profile "
}

# 修改参数
# SELINUX setenforce 0
change_selinux() {
    sshUpdate $1 'setenforce 0'
    if [[ -z $(sshUpdate $1 'grep "^SELINUX=" /etc/selinux/config') ]]; then
        sshUpdate $1 'echo "SELINUX=disabled" >> /etc/selinux/config'
    else
        sshUpdate $1 'sed -i "s/^SELINUX *=.*/SELINUX=disabled/" /etc/selinux/config'
    fi
    if [[ -n $(sshUpdate $1 'grep "^SELINUXTYPE" /etc/selinux/config') ]]; then
        sshUpdate $1 'sed -i "s/^SELINUXTYPE *=.*/#SELINUXTYPE/" /etc/selinux/config'
    fi
    SELINUX=$(sshUpdate $1 'grep "^SELINUX=" /etc/selinux/config')
    echo -e "SELINUX:"${SELINUX##*=}
}

# hugepage madvise
function change_huge() {
    sshUpdate $1 'echo madvise > /sys/kernel/mm/transparent_hugepage/defrag'
    sshUpdate $1 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled'
    sshUpdate $1 'chmod +x /etc/rc.d/rc.local'
    sshUpdate $1 'echo "echo madvise > /sys/kernel/mm/transparent_hugepage/defrag" >> /etc/rc.local'
    sshUpdate $1 'echo "echo madvise > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.local'
    echo -e "hugepage:"$(sshUpdate $1 'cat /sys/kernel/mm/transparent_hugepage/defrag')
}

#swappiness 0
function change_swap() {
    sshUpdate $1 'echo "0" > /proc/sys/vm/swappiness'
    if [[ -z $(sshUpdate $1 'grep "vm.swappiness" /etc/sysctl.conf') ]]; then
        sshUpdate $1 'echo "vm.swappiness=0" >> /etc/sysctl.conf'
    else
        sshUpdate $1 'sed -i "s/^vm.swappiness *=.*/vm.swappiness=0/" /etc/sysctl.conf'
    fi
}

# overcommit_memory 1
function change_overcommit() {
    sshUpdate $1 'echo "1" >> /proc/sys/vm/overcommit_memory'
    if [[ -z $(sshUpdate $1 'grep "vm.overcommit_memory" /etc/sysctl.conf') ]]; then
        sshUpdate $1 'echo "vm.overcommit_memory=1" >> /etc/sysctl.conf'
    else
        sshUpdate $1 'sed -i "s/^vm.overcommit_memory *=.*/vm.overcommit_memory=1/" /etc/sysctl.conf'
    fi
}

# somaxconn 1024
function change_somaxconn() {
    sshUpdate $1 'echo "1024" >> /proc/sys/net/core/somaxconn'
    if [[ -z $(sshUpdate $1 'grep "net.core.somaxconn" /etc/sysctl.conf') ]]; then
        sshUpdate $1 'echo "net.core.somaxconn=1024" >> /etc/sysctl.conf'
    else
        sshUpdate $1 'sed -i "s/^net.core.somaxconn *=.*/net.core.somaxconn=1024/" /etc/sysctl.conf'
    fi
}

#tcp_abort_on_overflow 1
function change_tcp() {
    sshUpdate $1 'echo "1" >> /proc/sys/net/ipv4/tcp_abort_on_overflow'
    if [[ -z $(sshUpdate $1 'grep "net.ipv4.tcp_abort_on_overflow" /etc/sysctl.conf') ]]; then
        sshUpdate $1 'echo "net.ipv4.tcp_abort_on_overflow=1" >> /etc/sysctl.conf'
    else
        sshUpdate $1 'sed -i "s/^net.ipv4.tcp_abort_on_overflow *=.*/net.ipv4.tcp_abort_on_overflow=1/" /etc/sysctl.conf'
    fi
}

#设置max_map_count参数 1
function change_mmc() {
    sshUpdate $1 'echo "262144" >> /proc/sys/vm/max_map_count'
    # 配置文件/etc/sysctl.conf， 设置max_map_count参数
    if [[ -z $(sshUpdate $1 'grep "vm.max_map_count" /etc/sysctl.conf') ]]; then
        sshUpdate $1 'echo "vm.max_map_count=262144" >> /etc/sysctl.conf'
    else
        sshUpdate $1 'sed -i "s/^vm.max_map_count *=.*/vm.max_map_count = 262144/" /etc/sysctl.conf'
    fi
}

# 资源限制
function change_limit() {
    # 临时修改该参数
    sshUpdate $1 'ulimit -n 65536'
    sshUpdate $1 'ulimit -u 65536'
    # 在文件 /etc/security/limits.conf 添加配置
    if [[ -z $(sshUpdate $1 'grep "^*.*soft.*nproc" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* soft nproc 65535" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *soft *nproc.*/* soft nproc 65535/" /etc/security/limits.conf'
    fi

    if [[ -z $(sshUpdate $1 'grep "^*.*hard.*nproc" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* hard nproc 65535" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *hard *nproc.*/* hard nproc 65535/" /etc/security/limits.conf'
    fi

    if [[ -z $(sshUpdate $1 'grep "^*.*soft.*nofile" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* soft nofile 65535" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *soft *nofile.*/* soft nofile 65535/" /etc/security/limits.conf'
    fi

    if [[ -z $(sshUpdate $1 'grep "^*.*hard.*nofile" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* hard nofile 65535" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *hard *nofile.*/* hard nofile 65535/" /etc/security/limits.conf'
    fi

    if [[ -z $(sshUpdate $1 'grep "^*.*soft.*stack" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* soft stack unlimited" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *soft *stack.*/* soft stack unlimited/" /etc/security/limits.conf'
    fi

    if [[ -z $(sshUpdate $1 'grep "^*.*hard.*stack" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* hard stack unlimited" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *hard *stack.*/* hard stack unlimited/" /etc/security/limits.conf'
    fi

    if [[ -z $(sshUpdate $1 'grep "^*.*soft.*memlock" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* soft memlock unlimited" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *soft *memlock.*/* soft memlock unlimited/" /etc/security/limits.conf'
    fi

    if [[ -z $(sshUpdate $1 'grep "^*.*hard.*memlock" /etc/security/limits.conf') ]]; then
        sshUpdate $1 'echo "* hard memlock unlimited" >> /etc/security/limits.conf'
    else
        sshUpdate $1 'sed -i "s/^* *hard *memlock.*/* hard memlock unlimited/" /etc/security/limits.conf'
    fi

    # 配置文件/etc/security/limits.d/20-nproc.conf， 设置soft nproc参数
    if [[ -z $(sshUpdate $1 'grep "^*.*soft.*proc" /etc/security/limits.d/20-nproc.conf') ]]; then
        sshUpdate $1 'echo "* soft nproc 65535" >> /etc/security/limits.d/20-nproc.conf'
    else
        sshUpdate $1 'sed -i "s/^* *soft *nproc.*/* soft nproc 65535/" /etc/security/limits.d/20-nproc.conf'
    fi

    # 配置文件/etc/security/limits.d/20-nproc.conf， 设置soft nproc参数
    if [[ -z $(sshUpdate $1 'grep "^root.*soft.*proc" /etc/security/limits.d/20-nproc.conf') ]]; then
        sshUpdate $1 'echo "root soft nproc 65535" >> /etc/security/limits.d/20-nproc.conf'
    else
        sshUpdate $1 'sed -i "s/^root *soft *nproc.*/root soft nproc 65535/" /etc/security/limits.d/20-nproc.conf'
    fi

    echo -e "ulimit -u:"$(sshUpdate $1 'ulimit -u')
    echo -e "ulimit -n:"$(sshUpdate $1 'ulimit -n')
}

# 检查指定节点信息
function node_check() {
    # 对节点进行检查
    node_check_predata="$(echo_color yellow "节点IP"),$(echo_color yellow " 打开文件数"),$(echo_color yellow " SWAPPINESS 开关"),$(echo_color yellow " JDK 检查"),$(echo_color yellow " OVERCOMMIT_MEMORY"),$(echo_color yellow " CPU"),$(echo_color yellow " 最大进程数"),$(echo_color yellow " Huge Pages"),$(echo_color yellow " Somaxconn"),$(echo_color yellow " tcp_abort_on_overflow"),$(echo_color yellow " selinux check"),$(echo_color yellow " 节点内存"),$(echo_color yellow " 是否发生OOM"),$(echo_color yellow " 内存是否故障"),$(echo_color yellow " 磁盘属性"),$(echo_color yellow " VMA 数量"),$(echo_color yellow " clock check")\n"

    for hostname in $*; do
        {
            $(ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 ${exe_user}@$hostname "pwd" &>/dev/null)
            if [ $? != 0 ]; then
                node_disconnect+=("$hostname")
                continue
            else
                #echo $hostname
                nodeConn=$(echo_color green $hostname)
                # 检查 swappiness
                nodeSwap=$(check_swap $hostname)
                # 检查 文件打开数
                nodeUlimitn=$(check_ulimitn $hostname)
                # 检查 jdk
                nodeJDK=$(jdk_check $hostname)
                # 检查 overcommit_memory
                nodeOvercommit=$(check_overcommit $hostname)
                # 检查cpu
                nodeCpu=$(cpu_check $hostname)
                # 检查单用户最大进程数上限
                nodeUlimitu=$(check_ulimitu $hostname)
                # 检查 hugepage,默认关闭
                nodeHuge=$(hugepage_check $hostname)
                # 检查socket监听(listen)的backlog上限
                nodeSomaxconn=$(check_somaxconn $hostname)
                # 检查 tcp_abort_on_overflow
                nodeCheck_tcp_overflow=$(check_tcp_overflow $hostname)
                # 查看防火墙状态
                nodeCheck_selinux=$(check_selinux $hostname)
                # 查看节点内存
                nodeCheck_sys_mem=$(check_sys_mem $hostname)
                # 查看节点是否发生了 OOM
                nodeCheck_oom_error=$(check_oom_error $hostname)
                # 查看节点是否有内存故障
                nodeCheck_mem_error=$(check_mem_error $hostname)
                # 查看节点磁盘属性
                nodeCheck_disk_prop=$(check_disk_prop $hostname)
                # 时钟检查
                nodeCheck_clock=$(check_clock $hostname)
                # 检查进程可以拥有的VMA(虚拟内存区域)的数量
                check_max_map_count=$(check_max_map_count $hostname)

                detail="$nodeConn,$nodeUlimitn,$nodeSwap,$nodeJDK,$nodeOvercommit,$nodeCpu,$nodeUlimitu,$nodeHuge,$nodeSomaxconn,$nodeCheck_tcp_overflow,$nodeCheck_selinux,$nodeCheck_sys_mem,$nodeCheck_oom_error,$nodeCheck_mem_error,$nodeCheck_disk_prop,$check_max_map_count,$nodeCheck_clock"
                node_check_predata="${node_check_predata}${detail}\n"
            fi
        }
    done

    for dis_host in "${node_disconnect[@]}"; do
        detail="$(echo_color red ${dis_host}" 节点免密未打通"),"
        node_check_predata="${node_check_predata}${detail}\n"
    done

    echo_table $node_check_predata
}

# fe_check_predata=""
# be_check_predata=""
# fe_disconnect=()
# be_disconnect=()
# be_checked=()
# fe节点进行检查
function fe_check() {
    fe_check_predata="$(echo_color yellow "FE节点IP"),$(echo_color yellow " 打开文件数"),$(echo_color yellow " SWAPPINESS 开关"),$(echo_color yellow " JDK 检查"),$(echo_color yellow " Xmx 值检查"),$(echo_color yellow " OVERCOMMIT_MEMORY"),$(echo_color yellow " CPU"),$(echo_color yellow " 最大进程数"),$(echo_color yellow " Huge Pages"),$(echo_color yellow " Somaxconn"),$(echo_color yellow " tcp_abort_on_overflow"),$(echo_color yellow " selinux check"),$(echo_color yellow " 节点内存"),$(echo_color yellow " 是否发生OOM"),$(echo_color yellow " 内存是否故障"),$(echo_color yellow " 磁盘属性"),$(echo_color yellow " VMA 数量")\n"
    for hostname in ${feIps}; do
        {
            $(ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 ${exe_user}@$hostname "pwd" &>/dev/null)
            if [ $? != 0 ]; then
                fe_disconnect+=("$hostname")
                continue
            else
                # echo $hostname
                feconn=$(echo_color green $hostname)
                # 检查 swappiness
                feswap=$(check_swap $hostname)
                # 检查 文件打开数
                feUlimitn=$(check_ulimitn $hostname)
                # 检查 jdk
                feJDK=$(jdk_check $hostname)
                # 检查 Xmx 大小
                fe_check_Xmx=$(check_Xmx $hostname)
                # 检查 overcommit_memory
                feOvercommit=$(check_overcommit $hostname)
                # 检查 cpu
                feCpu=$(cpu_check $hostname)
                # 检查单用户最大进程数上限
                feUlimitu=$(check_ulimitu $hostname)
                # 检查 hugepage,默认关闭
                feHuge=$(hugepage_check $hostname)
                # 检查socket监听(listen)的backlog上限
                feSomaxconn=$(check_somaxconn $hostname)
                # 检查 tcp_abort_on_overflow
                feCheck_tcp_overflow=$(check_tcp_overflow $hostname)
                # 查看防火墙状态
                feCheck_selinux=$(check_selinux $hostname)
                # 查看节点内存
                feCheck_sys_mem=$(check_sys_mem $hostname)
                # 查看节点是否发生了 OOM
                feCheck_oom_error=$(check_oom_error $hostname)
                # 查看节点是否有内存故障
                feCheck_mem_error=$(check_mem_error $hostname)
                # 查看节点磁盘属性
                feCheck_disk_prop=$(check_disk_prop $hostname)
                # 检查进程可以拥有的VMA(虚拟内存区域)的数量
                check_max_map_count=$(check_max_map_count $hostname)

                detail="$feconn,$feUlimitn,$feswap,$feJDK,$fe_check_Xmx,$feOvercommit,$feCpu,$feUlimitu,$feHuge,$feSomaxconn,$feCheck_tcp_overflow,$feCheck_selinux,$feCheck_sys_mem,$feCheck_oom_error,$feCheck_mem_error,$feCheck_disk_prop,$check_max_map_count"
                fe_check_predata="${fe_check_predata}${detail}\n"
            fi
        } #&
    done

    for fehost in "${fe_disconnect[@]}"; do
        detail="$(echo_color red ${fehost}" 节点免密未打通"),"
        fe_check_predata="${fe_check_predata}${detail}\n"
    done
    echo_table $fe_check_predata
}

function be_check() {
    # be节点进行检查
    be_check_predata="$(echo_color yellow "BE节点IP"),$(echo_color yellow " 打开文件数"),$(echo_color yellow " SWAPPINESS 开关"),$(echo_color yellow " JDK 检查"),$(echo_color yellow " OVERCOMMIT_MEMORY"),$(echo_color yellow " CPU"),$(echo_color yellow " 最大进程数"),$(echo_color yellow " Huge Pages"),$(echo_color yellow " Somaxconn"),$(echo_color yellow " tcp_abort_on_overflow"),$(echo_color yellow " selinux check"),$(echo_color yellow " 节点内存"),$(echo_color yellow " 是否发生OOM"),$(echo_color yellow " 内存是否故障"),$(echo_color yellow " 磁盘属性"),$(echo_color yellow " VMA 数量")\n"

    for hostname in ${beIps}; do
        {
            $(ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 ${exe_user}@$hostname "pwd" &>/dev/null)
            if [ $? != 0 ]; then
                be_disconnect+=("$hostname")
                continue
            else
                for checked_ip in ${feIps}; do
                    {
                        if [[ $checked_ip == $hostname ]]; then
                            be_checked+=("$checked_ip")
                            continue 2
                        fi
                    }
                done
                #echo $hostname
                beconn=$(echo_color green $hostname)
                # 检查 swappiness
                beswap=$(check_swap $hostname)
                # 检查 文件打开数
                beUlimitn=$(check_ulimitn $hostname)
                # 检查 jdk
                beJDK=$(jdk_check $hostname)
                # 检查 overcommit_memory
                beOvercommit=$(check_overcommit $hostname)
                # 检查cpu
                beCpu=$(cpu_check $hostname)
                # 检查单用户最大进程数上限
                beUlimitu=$(check_ulimitu $hostname)
                # 检查 hugepage,默认关闭
                beHuge=$(hugepage_check $hostname)
                # 检查socket监听(listen)的backlog上限
                beSomaxconn=$(check_somaxconn $hostname)
                # 检查 tcp_abort_on_overflow
                beCheck_tcp_overflow=$(check_tcp_overflow $hostname)
                # 查看防火墙状态
                beCheck_selinux=$(check_selinux $hostname)
                # 查看节点内存
                beCheck_sys_mem=$(check_sys_mem $hostname)
                # 查看节点是否发生了 OOM
                beCheck_oom_error=$(check_oom_error $hostname)
                # 查看节点是否有内存故障
                beCheck_mem_error=$(check_mem_error $hostname)
                # 查看节点磁盘属性
                beCheck_disk_prop=$(check_disk_prop $hostname)
                # 检查进程可以拥有的VMA(虚拟内存区域)的数量
                check_max_map_count=$(check_max_map_count $hostname)

                detail="$beconn,$beUlimitn,$beswap,$beJDK,$beOvercommit,$beCpu,$beUlimitu,$beHuge,$beSomaxconn,$beCheck_tcp_overflow,$beCheck_selinux,$beCheck_sys_mem,$beCheck_oom_error,$beCheck_mem_error,$beCheck_disk_prop,$check_max_map_count"
                be_check_predata="${be_check_predata}${detail}\n"
            fi
        } #&
    done

    for be_checked_host in "${be_checked[@]}"; do
        detail="$(echo_color green $be_checked_host" 节点已经检查过"),"
        be_check_predata="${be_check_predata}${detail}\n"
    done

    for be_dis_host in "${be_disconnect[@]}"; do
        detail="$(echo_color red ${be_dis_host}" 节点免密未打通"),"
        be_check_predata="${be_check_predata}${detail}\n"
    done

    echo_table $be_check_predata
}

# fe 进程参数进行检查
function fe_pid_check() {
    fe_check_predata="$(echo_color yellow "FE节点IP"),$(echo_color yellow " FE_PID ulimit -u"),$(echo_color yellow " FE_PID ulimit -n"),$(echo_color yellow " clock check")\n"
    for hostname in ${feIps}; do
        {
            $(ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 ${exe_user}@$hostname "pwd" &>/dev/null)
            if [ $? != 0 ]; then
                fe_disconnect+=("$hostname")
                continue
            else
                # echo $hostname
                feconn=$(echo_color green $hostname)
                # check FE 进程连接最大进程数
                check_FE_pid_ulimitu=$(check_FE_pid_ulimitu $hostname)
                # check FE 进程文件打开数
                check_FE_pid_ulimitn=$(check_FE_pid_ulimitn $hostname)
                # 时钟检查
                feCheck_clock=$(check_clock $hostname)

                detail="$feconn,$check_FE_pid_ulimitu,$check_FE_pid_ulimitn,$feCheck_clock"
                fe_check_predata="${fe_check_predata}${detail}\n"
            fi
        } #&
    done

    for fehost in "${fe_disconnect[@]}"; do
        detail="$(echo_color red ${fehost}" 节点免密未打通"),"
        fe_check_predata="${fe_check_predata}${detail}\n"
    done
    echo_table $fe_check_predata
}

# be节点进程属性进行检查
function be_pid_check() {
    be_check_predata="$(echo_color yellow "BE节点IP"),$(echo_color yellow " BE_PID ulimit -u"),$(echo_color yellow " BE_PID ulimit -n"),$(echo_color yellow " clock check")\n"

    for hostname in ${beIps}; do
        {
            $(ssh -o ConnectTimeout=3 -o PasswordAuthentication=no -o NumberOfPasswordPrompts=0 ${exe_user}@$hostname "pwd" &>/dev/null)
            if [ $? != 0 ]; then
                be_disconnect+=("$hostname")
                continue
            else
                #echo $hostname
                beconn=$(echo_color green $hostname)
                # check BE 进程连接最大进程数
                check_BE_pid_ulimitu=$(check_BE_pid_ulimitu $hostname)
                # check BE 进程文件打开数
                check_BE_pid_ulimitn=$(check_BE_pid_ulimitn $hostname)
                # 时钟检查
                beCheck_clock=$(check_clock $hostname)

                detail="$beconn,$check_BE_pid_ulimitu,$check_BE_pid_ulimitn,$beCheck_clock"
                be_check_predata="${be_check_predata}${detail}\n"
            fi
        } #&
    done

    for be_dis_host in "${be_disconnect[@]}"; do
        detail="$(echo_color red ${be_dis_host}" 节点免密未打通"),"
        be_check_predata="${be_check_predata}${detail}\n"
    done

    echo_table $be_check_predata
}

# 批量修改配置
function change_opt() {
    change_selinux $1
    change_huge $1
    change_swap $1
    change_limit $1
    change_overcommit $1
    change_somaxconn $1
    change_tcp $1
    change_mmc $1
    # 刷新配置
    sshUpdate $1 'sysctl -p'
}

# 修改节点配置信息
function node_change() {
    echo "********************************************************************************************$(echo_color green "开始修改节点系统配置")***************************************************************************************************"
    for hostname in $*; do
        {
            echo "******************************************************************************************$(echo_color green "开始修改 $hostname 节点属性")***********************************************************************************************"
            change_opt $hostname
            echo "******************************************************************************************$(echo_color green "修改 $hostname 节点属性完成")***********************************************************************************************"
        }
    done
    echo "********************************************************************************************$(echo_color green "节点系统参数修改完成")***************************************************************************************************"
}

# fe节点配置修改
function fe_change() {
    echo "********************************************************************************************$(echo_color green "开始修改 FE 节点属性")***************************************************************************************************"
    for hostname in ${feIps}; do
        {
            echo "******************************************************************************************$(echo_color green "开始修改 $hostname 节点属性")***********************************************************************************************"
            change_opt $hostname
            echo "******************************************************************************************$(echo_color green "修改 $hostname 节点属性完成")***********************************************************************************************"
        }
    done
    echo "********************************************************************************************$(echo_color green "FE 节点参数修改完成")****************************************************************************************************"
    echo -e "\n"
}

# be 节点修改，节点如果已经修改完成，则进行跳过

function be_change() {
    echo "********************************************************************************************$(echo_color yellow "开始修改 BE 节点属性")***************************************************************************************************"
    for be_hostname in ${beIps}; do
        {
            for checked_ip in ${feIps}; do
                {
                    if [[ $checked_ip == $be_hostname ]]; then
                        echo "******************************************************************************************$(echo_color green "开始修改 $be_hostname 节点属性")***********************************************************************************************"
                        echo_color green "$be_hostname  has been checked"
                        echo "******************************************************************************************$(echo_color green "修改 $be_hostname 节点属性完成")***********************************************************************************************"
                        continue 2
                    fi
                }
            done
            echo "******************************************************************************************$(echo_color yellow "开始修改 $be_hostname 节点属性")***********************************************************************************************"
            change_opt $be_hostname
            echo "******************************************************************************************$(echo_color yellow "修改 $be_hostname 节点属性完成")***********************************************************************************************"
        }
    done
    echo "********************************************************************************************$(echo_color yellow "BE 节点参数修改完成")****************************************************************************************************"
}

if [[ -n $node_list ]]; then
    if [[ "update" = $opt_flag ]]; then
        NOW=$(date +"%Y%m%d")
        cp -r /etc/ /etc.bak.${NOW}
        # 修改节点配置
        node_change $node_list
    else
        echo_color red "--------------------------------------------------------------------------------------------------"
        echo_color red "| 请注意：                                                                                       |"
        echo_color red "|   磁盘调度算法目前不支持在程序中检测，需要自行检查                                             |"
        echo_color red "|   时钟同步检查,因不同节点执行时间不同会有差异,相邻两个节点之间时间差值较大可以额外检查时钟同步 |"
        echo_color red "--------------------------------------------------------------------------------------------------"
        # 查看对应节点的配置信息
        node_check $node_list
    fi
else
    # 非手动指定节点，指定连接信息，对集群进行相关操作
    if [[ "update" = $opt_flag ]]; then
        NOW=$(date +"%Y%m%d")
        cp -r /etc/ /etc.bak.${NOW}
        # fe节点配置修改
        fe_change
        # be节点配置修改
        be_change
    else
        echo_color red "--------------------------------------------------------------------------------------------------"
        echo_color red "| 请注意：                                                                                       |"
        echo_color red "|   磁盘调度算法目前不支持在程序中检测，需要自行检查                                             |"
        echo_color red "|   时钟同步检查,因不同节点执行时间不同会有差异,相邻两个节点之间时间差值较大可以额外检查时钟同步 |"
        echo_color red "--------------------------------------------------------------------------------------------------"
        # fe节点进行检查
        echo_color red "############################################################################################################################ 系统参数检查 ############################################################################################################################"
        fe_check
        echo -e "\n"
        # be节点进行检查
        be_check
        echo -e "\n"
        echo_color red "############################################################### 进程参数检查 ###############################################################"
        # 检查 fe 进程参数
        fe_pid_check
        echo -e "\n"
        # 检查 be 进程参数
        be_pid_check
        echo -e "\n"
        # 检查集群参数
        checkVariables
    fi
fi

exit 0

#sed -i 's/\r//g' env_check.sh
