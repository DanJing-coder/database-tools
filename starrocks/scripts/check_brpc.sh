#!/bin/bash
#config
user=root
passwd=xxx
fe_ip=xxx
be_ip=xxx
#show backends看到的xxx节点对应的backendid
backend_id=xxx
brpc_port=8060
query_port=9030
timeout=10
pstack_path=/tmp/
timeout_times=0
interval=30
while true
do
    # call show proc '/statistic' to check db deadlock
    start_time=$(date +%s)
    curl http://${be_ip}:${brpc_port}/vars 1>/dev/null --max-time ${timeout}
    succ=$?
    end_time=$(date +%s)
    # check result, if return failed and time used is at least ${timeout}, increase timeout_times
    if [ ${succ} -ne 0 ]; then
        echo "start to print stack"
        pstack_file_name=${pstack_path}/pstack_$(date '+%Y%m%d-%H%M%S').txt
        mysql -h ${fe_ip} -u ${user} -P ${query_port} -p ${passwd} -e "admin execute on ${backend_id} 'System.print(ExecEnv.get_stack_trace_for_all_threads())'"
    fi
    sleep ${interval}
done
