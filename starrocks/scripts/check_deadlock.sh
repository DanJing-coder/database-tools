#!/bin/bash

#config
user=root
passwd=sr@2024
fe_ip=127.0.0.1
http_port=8232
timeout=10
max_timeout_times=3
jdk_path=/home/disk1/sr/app/starrocks-1031/agent/java-se-8u322-b06/bin
fe_bin_path=/home/disk1/sr/app/starrocks-2.3.3/fe-202407112047-aa94b3cab5f143789af42fe54b73bea0/bin
jmap_path=/home/disk1/sr/app/starrocks-2.3.3/fe-202407112047-aa94b3cab5f143789af42fe54b73bea0/log


timeout_times=0
interval=60
while true
do
    # call show proc '/statistic' to check db deadlock
    start_time=$(date +%s)
    curl -u ${user}:${passwd} http://${fe_ip}:${http_port}/api/show_proc?path=/statistic --max-time ${timeout}
    succ=$?
    end_time=$(date +%s)

    # check result, if return failed and time used is at least ${timeout}, increase timeout_times
    if [ ${succ} -ne 0 ]; then
	if [ $(($end_time - $start_time)) -ge ${timeout} ]; then
       	    timeout_times=$(($timeout_times + 1))
            # reduce interval, so that we can detect deadlock ASAP
            interval=5
            echo -e "\ntimeout, time used: $(($end_time - $start_time))"
        else
            timeout_times=0
            echo -e "\ncheck failed, time used: $(($end_time - $start_time))"
        fi
    else
        timeout_times=0
        interval=5
        echo -e "\ncheck successfully, time used: $(($end_time - $start_time))"
    fi

    # check ${timeout_times}, if ${timeout_times} >= max_timeout_times print jstack and stop fe
    # we will not start fe, Because the process is hosted by supervisor
    if [ ${timeout_times} -ge ${max_timeout_times} ]; then
        echo "successive timeout times is ${timeout_times}, print jmap"
        
        echo "start to print jmap"
        pid=`cat ${fe_bin_path}/fe.pid`
        jmap_file_name=${jmap_path}/jmap_$(date '+%Y%m%d-%H%M%S').txt
        jmap_dump_file_name=${jmap_path}/jmap_dump_$(date '+%Y%m%d-%H%M%S').txt
        ${jdk_path}/jmap -histo:live ${pid} > ${jmap_file_name}
        if [[ $? -ne 0 ]];then
            ${jdk_path}/jmap -dump:live,format=b,file=dump.hprof ${pid} > ${jmap_dump_file_name}
        fi

        timeout_times=0
    fi

    sleep ${interval}
done
