#!/bin/bash

# --- 配置信息 ---
SR_HOST="127.0.0.1"       # 源集群 FE 地址
SR_PORT="9030"            # 查询端口 (MySQL 协议端口)
SR_USER="root"            # 用户名
SR_PASS="your_password"   # 密码
OUTPUT_FILE="sr_backup_ddl.sql"

# 排除的系统数据库
EXCLUDE_DBS="'information_schema', '_statistics_','sys'"

# 清空旧的导出文件
echo "-- StarRocks Schema Backup --" > $OUTPUT_FILE
echo "-- Generated at: $(date)" >> $OUTPUT_FILE
echo "SET FOREIGN_KEY_CHECKS=0;" >> $OUTPUT_FILE

# 1. 获取所有数据库列表
databases=$(mysql -h${SR_HOST} -P${SR_PORT} -u${SR_USER} -p${SR_PASS} -e "SHOW DATABASES;" -sN | grep -vE "information_schema|_statistics_")

for db in $databases; do
    echo "Processing database: $db"
    
    # 写入创建数据库语句
    echo -e "\n-- Database: $db" >> $OUTPUT_FILE
    echo "CREATE DATABASE IF NOT EXISTS \`$db\`;" >> $OUTPUT_FILE
    echo "USE \`$db\`;" >> $OUTPUT_FILE

    # 2. 获取当前库下所有表名
    tables=$(mysql -h${SR_HOST} -P${SR_PORT} -u${SR_USER} -p${SR_PASS} -D"$db" -e "SHOW TABLES;" -sN)

    for tbl in $tables; do
        echo "  Exporting table: $tbl"
        
        # 3. 获取建表语句 (DDL)
        # 使用 sed 处理可能出现的换行符或格式问题
        ddl=$(mysql -h${SR_HOST} -P${SR_PORT} -u${SR_USER} -p${SR_PASS} -D"$db" -e "SHOW CREATE TABLE \`$tbl\`;" -sN | cut -f2)
        
        echo -e "\n-- Table: $tbl" >> $OUTPUT_FILE
        echo "$ddl;" >> $OUTPUT_FILE
    done
done

echo "-----------------------------------"
echo "导出完成！DDL 已保存至: $OUTPUT_FILE"