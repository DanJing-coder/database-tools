#!/bin/bash

# 定义ip列表
ip_list=("cs01" "cs02" "cs03")
ssh_port=22
be_port=8242

# 定义执行时长（分钟）
duration=60

current_date=$(date +"%Y-%m-%d_%H-%M")
end_time=$(date -d "$(date) + ${duration} minutes" +"%s")

# 输出文件路径
des_log_dir="/tmp/log-${current_date}"
mkdir -p "$des_log_dir"

start_time=$(date +"%s")
start_time_log=$(date +"%Y-%m-%d %H:%M:%S")
while [ $end_time -gt $start_time ]; do

  for ip in "${ip_list[@]}"; do
    echo -e "\nCommand executed on $ip at $start_time_log" >> ${des_log_dir}/${ip}.txt

    # 检查对应ip上是否有iostat和iotop命令，若没有则yum安装
    ssh -p"$ssh_port" $ip "sudo command -v iostat >/dev/null 2>&1 || sudo yum install -y sysstat"
    ssh -p"$ssh_port" $ip "sudo command -v iotop >/dev/null 2>&1 || sudo yum install -y iotop"

    # 获取8040端口的监听进程pid号
    pid=$(ssh -p"$ssh_port" $ip "sudo netstat -tlnp | grep :$be_port | awk '{print \$7}' | cut -d'/' -f1")

    for ((i=1; i<=5; i++)); do
    
        # 执行命令并将结果输出到文件
        echo -e "\niotstat on $ip" >> ${des_log_dir}/${ip}.txt
        ssh -p"$ssh_port" $ip "sudo iostat -x -y -t 1 1" >> ${des_log_dir}/${ip}.txt

        echo -e "\niotop on $ip" >> ${des_log_dir}/${ip}.txt
        ssh -p"$ssh_port" $ip "sudo iotop -b -o -n 1 | head -n 30" >> ${des_log_dir}/${ip}.txt

        echo -e "\nlsof on $ip" >> ${des_log_dir}/${ip}.txt
        ssh -p"$ssh_port" $ip "sudo lsof -p $pid | awk '\$4 ~ /r|u|w/ {print \$7, \$4, \$9}' | sort -nr | head -n 50" >> ${des_log_dir}/${ip}.txt
    
    done

  done

  sleep 30
  start_time=$(date +"%s")
  start_time_log=$(date +"%Y-%m-%d %H:%M:%S")
done