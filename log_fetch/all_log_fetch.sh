#!/bin/bash
# -*- coding: utf-8 -*-

# 定义日志的起始时间
start_time=$(date -v -1H +"%Y-%m-%d %H:%M")
end_time=$(date +"%Y-%m-%d %H:%M")

# 定义FE相关信息
fe_ip_list=("cs01" "cs02" "cs03")
fe_ssh_port=22
user="root"
password=""
fe_port=8232

# 定义BE相关信息
be_ip_list=("cs01" "cs03")
be_ssh_port=22
be_port=8242

# 定义帮助信息函数
show_help() {
    echo "Usage: $0 : Fetch logs of the given node. [options]"
    echo "Example: "
    echo "  Hybrid deployment:     sh all_log_fetch.sh -s '2023-12-07 14:30' -e '2023-12-08 11:54' -i cs01,cs02,cs03 -u root -p 123456"
    echo "  Standalone deployment: sh all_log_fetch.sh -s '2023-12-07 14:30' -e '2023-12-08 11:54' -f cs01,cs02 -b cs03,cs04 -u root -p 123456"
    echo "\nOptions:"
    echo "  -s   start_time       Set the start time for the logs, eg: '2023-12-07 14:30'. Default: current_datetime - 1 hour"
    echo "  -e   end_time         Set the end time for the logs, eg: '2023-12-08 11:54'. Default: current_datetime"
    echo "  -i   ip_list          Set the IP list of FE && BE nodes, eg: cs01,cs02,cs03. If set -i, donnot need to sed -f or -b."
    echo "  -P   ssh_port         Set the SSH port for FE && BE nodes, default: 22. If set -a, donnot need to sed -o or -r."
    echo "  -f   fe_ip_list       Set the IP list of FE nodes, eg: cs01,cs02,cs03"
    echo "  -o   fe_ssh_port      Set the SSH port for FE nodes, default: 22"
    echo "  -u   user             Set the user for StarRocks, eg: root"
    echo "  -p   password         Set the password for StarRocks, eg: 'abc@123'"
    echo "  -t   fe_port          Set the http port for FE, default: 8030"
    echo "  -b   be_ip_list       Set the IP list of BE nodes, eg: cs01,cs02,cs03"
    echo "  -r   be_ssh_port      Set the SSH port for BE nodes, default: 22"
    echo "  -w   be_port          Set the http port for BE, default: 8040"
    echo "  -h                    Display this help message"
}

# 使用 getopts 解析命令行选项
while getopts ":s:e:i:P:f:o:u:p:t:b:r:w:h" opt; do
    case $opt in
        s) start_time=$OPTARG
        ;;
        e) end_time=$OPTARG
        ;;
        i) IFS=',' read -r -a fe_ip_list <<< "$OPTARG"
           be_ip_list=("${fe_ip_list[@]}")
        ;;
        P) fe_ssh_port=$OPTARG
           be_ssh_port=$fe_ssh_port
        ;;
        f) IFS=',' read -r -a fe_ip_list <<< "$OPTARG"
        ;;
        o) fe_ssh_port=$OPTARG
        ;;
        u) user=$OPTARG
        ;;
        p) password=$OPTARG
        ;;
        t) fe_port=$OPTARG
        ;;
        b) IFS=',' read -r -a be_ip_list <<< "$OPTARG"
        ;;
        r) be_ssh_port=$OPTARG
        ;;
        w) be_port=$OPTARG
        ;;
        h) show_help
            exit 0
        ;;
        \?) show_help
            echo "Invalid option: -$OPTARG" >&2
            exit 1
        ;;
    esac
done

# test
test() {
    echo $start_time $end_time
    echo "${fe_ip_list[@]}"
    echo $fe_ssh_port $user $password $fe_port
    echo "${be_ip_list[@]}"
    echo $be_ssh_port $be_port
    exit 1
}
# test


# 定义日志的临时存储目录
des_log_dir="/tmp/all_log-$(date +'%Y-%m-%d_%H-%M')"
mkdir -p "$des_log_dir"

fetch_all_log(){
    # 循环远程执行脚本，并获取文件列表
    for ip in "${ip_list[@]}"; do
        echo ""
        echo $(date "+%Y-%m-%d %H:%M:%S") "Begin to fetch $file_name_patten logs from IP: $ip ..."
        # 将脚本发送到远程主机
        mkdir -p "$des_log_dir"
        scp -P $ssh_port log_fetch.sh $ip:/tmp/log_fetch.sh

        echo $(date "+%Y-%m-%d %H:%M:%S") "Collecting $file_name_patten logs on IP: $ip ..."
        # 在远程主机上执行脚本，并获取文件列表
        remote_files=$(ssh -p"$ssh_port" "$ip" "bash /tmp/log_fetch.sh -i $ip $script_args")
        # 判断remote_files是否为空
        if [ ${#remote_files[@]} -eq 0 ]; then
            echo $(date "+%Y-%m-%d %H:%M:%S") "No files found on $ip. Skipping..."
            continue
        fi

        echo $(date "+%Y-%m-%d %H:%M:%S") "Fetching $file_name_patten logs from IP: $ip ..."
        # 将远程文件拉取到本地
        echo "${remote_files[@]}"
        mkdir -p $des_log_dir/"$ip"_"$file_name_patten"_log
        for remote_file in "${remote_files[@]}"; do
            if [[ $remote_file =~ /tmp/.*${ip}.* ]]; then
                scp -P $ssh_port $ip:"$remote_file" $des_log_dir/"$ip"_"$file_name_patten"_log/
                # 删除远程主机上的脚本1和文件列表中的文件
                # ssh $ip "rm "$remote_file""
            else
                echo $remote_file
            fi
        done
        # ssh $ip "rm $des_log_dir/log_fetch.sh"

        echo $(date "+%Y-%m-%d %H:%M:%S") "Compressing $file_name_patten logs on localhost ..."
        # 压缩打包文件
        tar -cvzPf $des_log_dir/"$ip"_"$file_name_patten"_log.tar.gz $des_log_dir/"$ip"_"$file_name_patten"_log >/dev/null

        # 删除本地文件夹
        # rm -rf $des_log_dir/"$ip"_"$file_name_patten"_log
    done
}

if [ ${#be_ip_list[@]} -gt 0 ]; then
    ip_list=("${be_ip_list[@]}")
    ssh_port=$be_ssh_port
    script_args="-P $be_port -s \"$start_time\" -e \"$end_time\""
    file_name_patten="be"
    fetch_all_log
fi

if [ ${#fe_ip_list[@]} -gt 0 ]; then
    ip_list=("${fe_ip_list[@]}")
    ssh_port=$fe_ssh_port
    script_args="-u $user -p $password -P $fe_port -s \"$start_time\" -e \"$end_time\""
    file_name_patten="fe"
    fetch_all_log
fi
