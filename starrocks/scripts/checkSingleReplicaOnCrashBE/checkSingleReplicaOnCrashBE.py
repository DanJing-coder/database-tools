#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import csv
import argparse
import logging
import sys
import configparser
from typing import List, Dict, Any, Tuple
import pymysql
from pymysql import MySQLError as Error
from pymysql.connections import Connection

sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("starrocks_tablet_checker.log", encoding='utf-8'),
        logging.StreamHandler()
    ]
)

# 解析命令行参数（新增--config参数）
parser = argparse.ArgumentParser()
parser.add_argument('--config', type=str, default='db.ini', help='配置文件路径(默认: db.ini)')
parser.add_argument('--backend-id', type=str,  help='出现问题的 Backend ID')
parser.add_argument('--output-file', type=str, default='backend_tablets.csv', help='输出文件路径')
args = parser.parse_args()

# 读取配置文件
config = configparser.ConfigParser()
config.read(args.config)  # 使用命令行指定的配置文件路径

def get_db_config() -> Dict[str, Any]:  # 此处 Dict 已通过 typing 导入
    """从db.ini获取完整的数据库配置，支持命令行参数覆盖"""
    db_config = {
        'host': config.get('database', 'host'),
        'port': config.getint('database', 'port'),
        'user': config.get('database', 'user'),
        'password': config.get('database', 'password'),
    }
    return db_config

def connect_to_starrocks(config: Dict[str, Any]) -> Connection:
    try:
        connection = pymysql.connect(
            host=config['host'],
            port=config['port'],
            user=config['user'],
            password=config['password'],
            charset='utf8mb4',
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=False
        )
        logging.info("成功连接到StarRocks")
        return connection
    except Error as e:
        logging.error(f"连接数据库失败: {e}")
        sys.exit(1)

def execute_query(connection: Connection, query: str) -> List[Dict[str, Any]]:
    results = []
    with connection.cursor() as cursor:
        try:
            cursor.execute(query)
            results = cursor.fetchall()
            logging.debug(f"查询成功，返回 {len(results)} 条记录")
        except Error as e:
            logging.error(f"执行查询失败: {e}")
            raise e
    return results

def check_table_exists(connection: Connection, db_name: str, table_name: str) -> bool:
    query = f"SELECT COUNT(1) AS row_count FROM `{db_name}`.`{table_name}`"
    with connection.cursor() as cursor:
        try:
            cursor.execute(query)
            result = cursor.fetchone()
            if result and 'row_count' in result:
                row_count = result['row_count']
                logging.info(f"表 `{db_name}`.`{table_name}` 存在，共有 {row_count} 行记录")
                return True
            else:
                logging.warning(f"查询表 `{db_name}`.`{table_name}` 的行数失败，返回结果格式不正确")
                return False
        except Error as e:
            error_msg = str(e)
            if isinstance(e, pymysql.err.ProgrammingError) and e.args[0] == 1146:
                logging.warning(f"表 `{db_name}`.`{table_name}` 不存在: {error_msg}")
            else:
                logging.warning(f"查询表 `{db_name}`.`{table_name}` 的行数失败: {error_msg}")
            return False

def get_tablets(connection: Connection, db_name: str, table_name: str) -> List[Dict[str, Any]]:
    query = f"SHOW TABLET FROM `{db_name}`.`{table_name}`"
    return execute_query(connection, query)

def filter_and_save_tablets(tablets: List[Dict[str, Any]], output_file: str, target_backend_id: str) -> None:
    logging.info(f"获取到 {len(tablets)} 个tablet信息")
    for idx, tablet in enumerate(tablets, 1):
        logging.info(f"Tablet {idx}/{len(tablets)}: {tablet}")
    
    filtered_tablets = [t for t in tablets if str(t.get('BackendId')) == target_backend_id]
    
    if filtered_tablets:
        with open(output_file, 'a', newline='', encoding='utf-8') as csvfile:
            fieldnames = ['TABLET_ID', 'BACKEND_ID']
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            
            if csvfile.tell() == 0:
                writer.writeheader()
                
            for tablet in filtered_tablets:
                writer.writerow({
                    'TABLET_ID': tablet.get('TabletId'),
                    'BACKEND_ID': str(tablet.get('BackendId'))
                })
                
        logging.info(f"已将 {len(filtered_tablets)} 个tablet信息保存到 {output_file}")
    else:
        logging.info(f"没有找到BACKEND_ID为{target_backend_id}的tablet")

def main():
    parser = argparse.ArgumentParser(
        description='StarRocks Tablet检查工具',
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('--config', type=str, default='db.ini', help='配置文件路径')
    parser.add_argument('--backend-id', type=str, required=True, help='目标Backend ID')
    parser.add_argument('--output-file', type=str, default='backend_tablets.csv', help='输出文件路径')
    args = parser.parse_args()  # 必须添加此行以解析参数

    db_config = get_db_config()
    logging.info(f"连接配置: {db_config['user']}@{db_config['host']}:{db_config['port']}")
    connection = connect_to_starrocks(db_config)
    
    try:
        first_query = """
        SELECT DISTINCT
            pm.DB_NAME,
            pm.TABLE_NAME,
            pm.REPLICATION_NUM,
            t.TABLE_ID
        FROM
            information_schema.partitions_meta pm 
            LEFT JOIN information_schema.tables_config t 
                ON pm.DB_NAME = t.TABLE_SCHEMA AND pm.TABLE_NAME = t.TABLE_NAME
        WHERE
            pm.REPLICATION_NUM = 1
            AND pm.REPLICATION_NUM IS NOT NULL    
        """
        tables = execute_query(connection,  first_query)
        logging.info(f"找到 {len(tables)} 个REPLICATION_NUM为1的表")
        
        for table in tables:
            db_name = table['DB_NAME']
            table_name = table['TABLE_NAME']
            logging.info(f"正在处理表: `{db_name}`.`{table_name}`")
            
            if check_table_exists(connection, db_name, table_name):
                logging.info(f"表 `{db_name}`.`{table_name}` 可以正常查询，跳过")
                continue
                
            tablets = get_tablets(connection, db_name, table_name)
            filter_and_save_tablets(tablets, args.output_file, args.backend_id)
            
    except Exception as e:
        logging.error(f"执行过程中发生错误: {e}")
    finally:
        if connection.open:
            connection.close()
            logging.info("数据库连接已关闭")

if __name__ == "__main__":
    main()