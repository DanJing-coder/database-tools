# -*- coding: utf-8 -*-

import re
import sys
import argparse
import pymysql
import numpy as np
from prettytable import PrettyTable
from contextlib import contextmanager
import json

# 脚本的功能是分析StarRocks集群中各库表的健康度，主要通过SHOW PARTITIONS和SHOW TABLET命令获取分区和Tablet的统计信息，
# 计算每个表的总大小、分区数、副本数、平均Tablet大小和倾斜度（标准差）。支持按数据库过滤和输出格式选择（表格或JSON）。

# 设置 numpy 忽略无效警告
np.seterr(invalid='ignore')

class SRHealthChecker:
    def __init__(self, host, port, user, passwd, mode="shared_nothing"):
        self.host = host
        self.port = port
        self.user = user
        self.passwd = passwd
        self.mode = mode
        self.table_black_list = ['information_schema', '_statistics_', 'starrocks_monitor']

    @contextmanager
    def get_conn(self):
        try:
            conn = pymysql.connect(
                host=self.host,
                port=self.port,
                user=self.user,
                password=self.passwd,
                charset='utf8',
                autocommit=True
            )
            yield conn
            conn.close()
        except Exception as e:
            print(f"数据库连接失败: {e}")
            sys.exit(1)

    def convert_size_mb(self, size_str):
        if not size_str or size_str == 'NULL': return 0.0
        try:
            match = re.match(r'([0-9.]+)\s*([A-Za-z]*)', str(size_str))
            if match:
                num, unit = float(match.group(1)), match.group(2).upper()
                units = {"KB": 1/1024, "MB": 1, "GB": 1024, "TB": 1024*1024, "B": 1/(1024*1024), "": 1/(1024*1024)}
                return num * units.get(unit, 1)
        except:
            return 0.0
        return 0.0

    def get_valid_dbs(self, target_dbs=None):
        with self.get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("SHOW DATABASES")
            all_dbs = [r[0] for r in cursor.fetchall()]
            
            if target_dbs:
                return [d for d in target_dbs if d in all_dbs]
            return [d for d in all_dbs if d not in self.table_black_list]

    def run_report(self, target_dbs=None):
        dbs = self.get_valid_dbs(target_dbs)
        report_data = []

        with self.get_conn() as conn:
            cursor = conn.cursor()
            for db in dbs:
                sys.stderr.write(f"正在分析数据库: {db} ...\n") # 使用 stderr 打印进度，不影响重定向
                try:
                    cursor.execute(f"SHOW TABLES FROM `{db}`")
                    tables = [r[0] for r in cursor.fetchall()]
                except:
                    continue

                for table in tables:
                    try:
                        # 1. 获取分区统计
                        cursor.execute(f"SHOW PARTITIONS FROM `{db}`.`{table}`")
                        cols = [d[0] for d in cursor.description]
                        part_rows = cursor.fetchall()
                        
                        partition_count = len(part_rows)
                        total_size_mb = 0
                        replica_counts = 0
                        null_parts = 0

                        for row in part_rows:
                            r_dict = dict(zip(cols, row))
                            size_mb = self.convert_size_mb(r_dict.get('DataSize', 0))
                            total_size_mb += size_mb
                            
                            buckets = int(r_dict.get('Buckets', 0))
                            repl_num = int(r_dict.get('ReplicationNum', 1)) if self.mode == "shared_nothing" else 1
                            replica_counts += buckets * repl_num
                            
                            if size_mb == 0: null_parts += 1

                        # 2. 获取 Tablet 倾斜度
                        cursor.execute(f"SHOW TABLET FROM `{db}`.`{table}`")
                        t_cols = [d[0] for d in cursor.description]
                        tablet_rows = cursor.fetchall()
                        
                        tablet_sizes = []
                        for tr in tablet_rows:
                            tr_dict = dict(zip(t_cols, tr))
                            tsize = self.convert_size_mb(tr_dict.get('DataSize', 0))
                            if tsize > 0: tablet_sizes.append(tsize)
                        
                        std_dev = np.std(tablet_sizes) if len(tablet_sizes) > 1 else 0.0

                        report_data.append({
                            "Database": db,
                            "Table": table,
                            "Size(MB)": round(total_size_mb, 2),
                            "Partitions": partition_count,
                            "ReplicaCounts": replica_counts,
                            "AvgTablet(MB)": round(total_size_mb / replica_counts, 2) if replica_counts > 0 else 0,
                            "StdDev": round(std_dev, 2),
                            "EmptyParts": null_parts
                        })
                    except Exception as e:
                        continue

        return report_data

def main():
    parser = argparse.ArgumentParser(description='StarRocks 库表健康度分析工具')
    parser.add_argument('--host', default='localhost', help='FE Host')
    parser.add_argument('--port', type=int, default=9030, help='FE Query Port')
    parser.add_argument('--user', required=True, help='Username')
    parser.add_argument('--password', default='', help='Password')
    parser.add_argument('--databases', help='指定数据库，逗号分隔')
    parser.add_argument('--mode', default='shared_nothing', choices=['shared_nothing', 'shared_data'], help='集群模式')
    parser.add_argument('--format', default='table', choices=['table', 'json'], help='输出格式') # <--- 补齐了这里
    args = parser.parse_args()

    checker = SRHealthChecker(args.host, args.port, args.user, args.password, args.mode)
    
    db_list = [d.strip() for d in args.databases.split(',')] if args.databases else None
    results = checker.run_report(db_list)
    results.sort(key=lambda x: x['Size(MB)'], reverse=True)

    if args.format == 'json':
        print(json.dumps(results, indent=4))
    else:
        # 打印表格
        table = PrettyTable(['Database', 'Table', 'Size(MB)', 'Partitions', 'ReplicaCounts', 'AvgTablet(MB)', 'StdDev(倾斜度)', 'EmptyParts'])
        for r in results:
            table.add_row([
                r['Database'], r['Table'], r['Size(MB)'], r['Partitions'], 
                r['ReplicaCounts'], r['AvgTablet(MB)'], r['StdDev'], r['EmptyParts']
            ])
        print(table)

if __name__ == "__main__":
    main()