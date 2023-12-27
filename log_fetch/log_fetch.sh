#!/bin/bash
# -*- coding: utf-8 -*-

# 参数设置
ip="127.0.0.1"
start_time=$(date -v -1H +"%Y-%m-%d %H:%M")
end_time=$(date +"%Y-%m-%d %H:%M")
user="root"
password=""
port="8242"

# 日志起始时间格式
be_log_patten="^[I|W|E][0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}"
fe_log_patten="^[0-9]{4}-[0-9]{2}-[0-9]{2}(T| )[0-9]{2}:[0-9]{2}:[0-9]{2}"

# 定义帮助信息函数
show_help() {
    echo "Usage: $0 : Fetch logs of the current node. [options]"
    echo "Example:"
    echo "  If FE: sh log_fetch.sh -s '2023-12-07 14:30' -e '2023-12-08 11:54' -u root -p 123456 -P 8030"
    echo "  If BE: sh log_fetch.sh -s '2023-12-07 14:30' -e '2023-12-08 11:54' -P 8040"
    echo "\nOptions:"
    echo "  -s   start_time       Set the start time for the logs, eg: '2023-12-07 14:30'. Default: current_datetime - 1 hour"
    echo "  -e   end_time         Set the end time for the logs, eg: '2023-12-08 11:54'. Default: current_datetime"
    echo "  -u   user             Set the user for StarRocks, eg: root"
    echo "  -p   password         Set the password for StarRocks, eg: 'abc@123'. It is used to identify if the current node is FE."
    echo "  -P   http_port        Set the http port for FE or BE, default: 8030"
    echo "  -h                    Display this help message"
}

while getopts "s:e:u:p:P:h" opt; do
    case $opt in
        s) start_time=$OPTARG
        ;;
        e) end_time=$OPTARG
        ;;
        u) user=$OPTARG
        ;;
        p) password=$OPTARG
        ;;
        P) port=$OPTARG
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
    echo $user $password $port
    exit 1
}
# test


# 将时间转换为Unix时间戳
start_timestamp=$(date -d "$start_time" +%s)
end_timestamp=$(date -d "$end_time" +%s)

# 定义日志的临时存储目录
des_log_dir="/tmp/log-$(date +'%Y-%m-%d_%H-%M')"
mkdir -p "$des_log_dir"

# 获取fe或be的日志的函数
fetch_log(){
    if [ -z "$log_directory" ]; then
        echo $(date "+%Y-%m-%d %H:%M:%S") "Cann't find the log directory of $log_name_patten" 
        log_files=()
    else
        log_files=$(find $log_directory -name "$log_name_patten*" -type f -print0 | xargs -0 ls -ltr | awk '{print $NF}')
    fi
    target_logs_tar=()
    # 循环处理每个日志文件
    for log_file in $log_files
    do
        # echo $log_file $(date "+%Y-%m-%d %H:%M:%S")
        # 防御下，万一格式不对直接退出后续处理逻辑
        if [[ "$log_file" != *"$log_name_patten"* ]]; then
            # echo $(date "+%Y-%m-%d %H:%M:%S") "The name format of" $log_file "is not like" *"$log_name_patten"*
            break
        fi
        # 获取文件大小（以字节为单位），如果文件大小是0，跳过
        file_size=$(stat -c%s "$log_file")
        if [ "$file_size" -eq 0 ]; then
            continue
        fi
        # 如果是fe.out或者be.out的话，看文件大小，如果小于1G之间cp后压缩，否则取最新的3000行日志
        if [ "$fetch_model" == "2" ]; then
            log_name="$des_log_dir/${ip}_${log_name_patten}"
            # 判断文件大小是否小于1G（1GB = 1024 * 1024 * 1024 字节）
            if [ "$file_size" -lt $((1024*1024*1024)) ]; then
                # 压缩文件
                cp "$log_file" "$log_name"
            else
                # 取最后3000行数据
                tail -n 3000 "$log_file" > "$log_name"
            fi
            tar -cvzPf "$log_name.tar.gz" "$log_name" >/dev/null
            target_logs_tar+=("$log_name.tar.gz")
            # rm "$log_name"
            break
        fi

        # 获取日志文件的第一行和最后一行对应的时间戳
        first_time=$(head -n 100 "$log_file" |grep -oE "$log_time_patten" |head -n 1)
        last_time=$(tail -n 100 "$log_file" |grep -oE "$log_time_patten" |tail -n 1)
        if [[ $log_file == *be* ]]; then
            year=$(echo "$log_file" | grep -oE '[0-9]{8}-[0-9]{6}' | cut -c 1-4)
            first_time=$(date -d "$year${first_time:1}" "+%Y-%m-%d %H:%M:%S")
            last_time=$(date -d "$year${last_time:1}" "+%Y-%m-%d %H:%M:%S")
        fi
        # echo $first_time $last_time

        first_timestamp=$(date -d "$first_time" +%s)
        last_timestamp=$(date -d "$last_time" +%s)

        # 日志命名的时间
        log_first_time=$(date -d "$first_time" "+%Y%m%d-%H%M")
        log_start_time=$(date -d "$start_time" "+%Y%m%d-%H%M")

        # 判断日志文件是否在所需范围内
        if [[ $first_timestamp -gt $end_timestamp ]]; then
            # 第一行日志对应的时间戳大于给定的结束时间，结束对该ip节点的循环
            break
        elif [[ $last_timestamp -lt $start_timestamp ]]; then
            # 最后一行日志对应的时间戳小于给定的起始时间，结束对这个日志的查找
            continue
        elif [[ $first_timestamp -ge $start_timestamp ]]; then
            # 第一行日志对应的时间戳大于等于给定的起始时间
            log_name="$des_log_dir/${ip}_${log_name_patten}_${log_first_time}"
            if [ "$fetch_model" == "1" ]; then
                cp "$log_file" "$log_name"
            else
                if [[ $last_timestamp -le $end_timestamp ]]; then
                    # 最后一行日志对应的时间戳小于等于给定的结束时间，直接获取整个文件
                    cp "$log_file" "$log_name"
                else
                    # 最后一行日志对应的时间戳大于给定的结束时间，获取需要的日志
                    end_line=$(grep -n -m 1 -E "^$end_time_patten" "$log_file" | cut -d':' -f1)
                    sed -n "1,$end_line p" "$log_file" > "$log_name"
                fi
            fi
            tar -cvzPf "$log_name.tar.gz" "$log_name" >/dev/null
            target_logs_tar+=("$log_name.tar.gz")
            # rm "$log_name"
        elif [[ $first_timestamp -lt $start_timestamp ]]; then
            # 第一行日志对应的时间戳小于给定的起始时间
            log_name="$des_log_dir/${ip}_${log_name_patten}_${log_start_time}"
            if [ "$fetch_model" == "1" ]; then
                cp "$log_file" "$log_name"
            else
                # 先通过grep定位到第一行大于等于给定的起始时间的日志
                start_line=$(grep -n -m 1 -E "^$start_time_patten" "$log_file" | cut -d':' -f1)
                if [[ $last_timestamp -le $end_timestamp ]]; then
                    # 最后一行日志对应的时间戳小于等于给定的结束时间，直接获取整个文件
                    sed -n "$start_line,\$p" "$log_file" > "$log_name"
                else
                    # 最后一行日志对应的时间戳大于给定的结束时间，获取需要的日志
                    end_line=$(grep -n -m 1 -E "^$end_time_patten" "$log_file" | cut -d':' -f1)
                    sed -n "$start_line,$end_line p" "$log_file" > "$log_name"
                fi
            fi
            tar -cvzPf "$log_name.tar.gz" "$log_name" >/dev/null
            target_logs_tar+=("$log_name.tar.gz")
            # rm "$log_name"
        fi
    done
    echo "${target_logs_tar[@]}"
}


# 若是传参设置了password的话便是只获取fe的日志，否则只获取be的日志
if [ -z "$password" ]; then
    file_array=()
    log_directory=$(curl -s 127.0.0.1:"$port"/varz|grep sys_log_dir|awk -F "=" '{print $2}')
    log_time_patten=$be_log_patten
    start_time_patten=$(date -d "$start_time" "+[I|W|E]%m%d %H:%M")
    end_time_patten=$(date -d "$end_time" "+[I|W|E]%m%d %H:%M")
    # 获取be.INFO日志
    log_name_patten="be.INFO"
    fetch_model=0
    file_array+=($(fetch_log))
    # 获取be.out日志
    log_name_patten="be.out"
    fetch_model=2
    file_array+=($(fetch_log))
    # 获取be的运行配置
    log_name="$des_log_dir/${ip}_be_run_$(date +'%Y%m%d').conf"
    curl -s 127.0.0.1:"$port"/varz |sed -E 's/.*>/''/g'|grep -v '^\s*$' > "$log_name"
    file_array+=("$log_name")
else
    log_directory=$(curl -s -u "$user":"$password" 127.0.0.1:"$port"/variable|grep sys_log_dir|awk -F "=" '{print $2}')
    log_time_patten=$fe_log_patten
    start_time_patten=$(date -d "$start_time" "+%Y-%m-%d(T| )%H:%M")
    end_time_patten=$(date -d "$end_time" "+%Y-%m-%d(T| )%H:%M")
    # 获取fe.log日志
    log_name_patten="fe.log"
    fetch_model=0
    file_array+=($(fetch_log))
    # 获取fe.gc.log日志
    log_name_patten="fe.gc.log"
    fetch_model=1
    file_array+=($(fetch_log))
    # 获取fe.out日志
    log_name_patten="fe.out"
    fetch_model=2
    file_array+=($(fetch_log))
    # 获取fe的运行配置
    log_name="$des_log_dir/${ip}_fe_run_$(date +'%Y%m%d').conf"
    curl -s -u "$user":"$password" 127.0.0.1:"$port"/variable |sed -E 's/.*>/''/g'|grep -v '^\s*$' > "$log_name"
    file_array+=("$log_name")
fi

echo "${file_array[@]}"
