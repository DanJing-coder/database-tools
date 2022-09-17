#!/bin/bash


function cpu_check(){
    echo ""
    echo "############################ check cpu vector #############################"
    cat /proc/cpuinfo |grep avx2 2>&1 >/dev/null
    if [ $? -ne 0 ];then
        echo -e "\033[31mcpu not support vector\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function jdk_check(){
    echo ""
    echo "############################ check JAVA_HOME #############################"
    if [ -z $JAVA_HOME ];then
        echo -e "\033[31mJAVA_HOME not set\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function swap_check(){
    echo ""
    echo "############################ check swap #############################"
    swap_number=$(cat /proc/sys/vm/swappiness)
    if [ $swap_number -ne 0 ];then
        echo -e "\033[31mswap not close,please \"echo 0 | sudo tee /proc/sys/vm/swappiness\"\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function kernel_check(){
    echo ""
    echo "############################ check  overcommit_memory #############################"
    oom_number=$(cat /proc/sys/vm/overcommit_memory)
    if [ $oom_number -ne 1 ];then
        echo -e "\033[31mplease \"echo 1 | sudo tee /proc/sys/vm/overcommit_memory\",details in https://www.kernel.org/doc/Documentation/vm/overcommit-accounting\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function ulimit_process_check(){
    echo ""
    echo "############################ check max process #############################"
    ulimit_ps=$(ulimit -u)
    if [ $ulimit_ps -lt 65535 ];then
        echo -e "\033[31mplease \"sed 's/soft nproc.*/soft nproc 65555/g' /etc/security/limits.conf\nsed 's/hard nproc.*/hard nproc 65555/g' /etc/security/limits.conf\",details in \033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function ulimit_files_check(){
    echo ""
    echo "############################ check max open files #############################"
    ulimit_fs=$(ulimit -n)
    if [ $ulimit_fs -lt 65535 ];then
        echo -e "\033[31mplease \"sed -i 's/soft nofile.*/soft nofile 65555/g' /etc/security/limits.conf\nsed -i 's/hard nofile.*/hard nofile 65555/g' /etc/security/limits.conf\"\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function fe_port_check(){
    echo ""
    echo "############################ check FE ports #############################"
    # default port 8030,9010,9020,9030
    ports=$(ss -antpl|grep -E '8030|9010|9020|9030'|wc -l)
    if [ $ports -ge 0 ];then
        echo -e "\033[31mFe ports already used,please use \"ss -antpl|grep -E '8030|9010|9020|9030'\" check and reconfig.\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function be_port_check(){
    echo ""
    echo "############################ check BE ports #############################"
    # default port 9060,9050,8040,8060
    ports=$(ss -antpl|grep -E '9060|9050|8040|8060'|wc -l)
    if [ $ports -ge 0 ];then
        echo -e "\033[31mBe ports already used,please use \"ss -antpl|grep -E '9060|9050|8040|8060'\" check and reconfig.\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function disk_check(){
    echo ""
    echo "############################ 磁盘容量检查 #############################"
    # disk space > 80%
    n=0
    for var in `df -hP | grep '^/dev/*' | awk '{print $5}' | sed 's/\([0-9]*\).*/\1/'`
    do
        if [ $var -gt 80 ];then
            echo -e "\033[31mdisck space is more than 80%,please use \"df -hP\" check and reconfig.\033[0m"
            n+=1
            break
        fi
    done
    if [ $n -eq 0 ];then
        echo -e "\033[32msuccess\033[0m"
    fi
}

function kernelversion_check(){
    echo ""
    echo "############################ check kernel version #############################"
    cat /proc/version
}

function linuxversion_check(){
    echo ""
    echo "############################ check linux version #############################"
    cat /etc/redhat-release
}

function jdkversion_check(){
    echo ""
    echo "############################ check jdk version #############################"
    java -version
}

function selinux_check(){
    echo ""
    echo "############################ check selinux #############################"
    selinux_value=$(getenforce)
    if [ $selinux_value == "Disabled" ];then
        echo -e "\033[32msuccess\033[0m"
    else
        echo -e "\033[31mselinux is running ,please use \"gentenforce\" check and reconfig.\033[0m"
    fi
}

function firewalld_check(){
    echo ""
    echo "############################ check firewalld #############################"
    firewalld_value=$(systemctl status firewalld | grep "running")
    if [ -z $firewalld_value ];then
        echo -e "\033[32msuccess\033[0m"
    else
        echo -e "\033[31mfirewalld is running ,please use \"systemctl status firewalld\" check and reconfig.\033[0m"
    fi
}

function hugepage_check(){
    echo ""
    echo "############################ check hugepage #############################"
    enabled_value=$(cat /sys/kernel/mm/transparent_hugepage/enabled | sed 's/\[\(.*\)\].*/\1/')
    if [ $enabled_value == "never" ];then
        echo -e "\033[31mtransparent_hugepage/enabled is set never ,please use \"cat /sys/kernel/mm/transparent_hugepage/enabled\" check and reconfig.\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
    defrag_value=$(cat /sys/kernel/mm/transparent_hugepage/defrag | sed 's/\[\(.*\)\].*/\1/')
     if [ $defrag_value == "never" ];then
        echo -e "\033[31mtransparent_hugepage/defrag is set never ,please use \"cat /sys/kernel/mm/transparent_hugepage/defrag\" check and reconfig.\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function tcp_abort_on_overflow_check(){
    echo ""
    echo "############################ check tcp_abort_on_overflow #############################"
    tcp_aoo=$(cat /proc/sys/net/ipv4/tcp_abort_on_overflow)
    if [ $tcp_aoo -eq 1 ];then
        echo -e "\033[32msuccess\033[0m"
    else
        echo -e "\033[31mtcp_abort_on_overflow is better set to 1 ,please use \"cat /proc/sys/net/ipv4/tcp_abort_on_overflow\" check and reconfig.\033[0m"
    fi
}

function somaxconn_check(){
    echo ""
    echo "############################ check somaxconn #############################"
    somaxconn_value=$(cat /proc/sys/net/core/somaxconn)
    if [ $somaxconn_value -eq 1024 ];then
        echo -e "\033[32msuccess\033[0m"
    else
        echo -e "\033[31msomaxconn is better set to 1024 ,please use \"cat /proc/sys/net/core/somaxconn\" check and reconfig.\033[0m"
    fi
}

function ntp_check(){
    echo ""
    echo "############################ check ntp #############################"
    systemctl status ntpd.service | grep running 2>&1 >/dev/null
    if [ $? -ne 0 ];then
        echo -e "\033[31mplease check whether the server time is consistent.\033[0m"
    else
        echo -e "\033[32msuccess\033[0m"
    fi
}

function check(){
    cpu_check
    jdk_check
    swap_check
    kernel_check
    ulimit_files_check
    ulimit_process_check
    fe_port_check
    be_port_check
    disk_check
    linuxversion_check
    kernelversion_check
    jdkversion_check
    selinux_check
    firewalld_check
    hugepage_check
    tcp_abort_on_overflow_check
    somaxconn_check
    ntp_check
}

check
