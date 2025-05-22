# -*- coding: utf-8 -*-

import re
import sys
import argparse
import pymysql
from prettytable import PrettyTable
import numpy as np
from contextlib import contextmanager
import json
import yaml
from datetime import datetime
import os

np.seterr(invalid='ignore')
RUN_MODE = "shared_nothing"

class DbHandler:
    def __init__(self, user, passwd="", db="", host="localhost", port=9030):
        self.host = host
        self.user = user
        self.passwd = passwd
        self.port = port
        self.dbName = db
        self.charset = "utf8"
        self.connection = None
        self.cursor = None

    @contextmanager
    def connect(self):
        """Context manager for database connection"""
        try:
            self.connection = pymysql.connect(
                host=self.host,
                user=self.user,
                password=self.passwd,
                db=self.dbName,
                port=self.port,
                charset=self.charset,
            )
            self.cursor = self.connection.cursor()
            yield self
        except pymysql.err.OperationalError as e:
            print(f"Connection failed: {e}")
            if "Errno 10060" in str(e) or "2003" in str(e):
                print("Connection timeout or refused")
            raise
        finally:
            if self.cursor:
                self.cursor.close()
            if self.connection:
                self.connection.close()

    def query(self, sql, params=None):
        """Execute a query and return results"""
        with self.connect():
            try:
                self.cursor.execute(sql, params or ())
                data = self.cursor.fetchall()
                fields = self.cursor.description
                return fields, data
            except Exception as e:
                print(f"Query failed: {e}")
                return None, None

    def format(self, fields, result):
        """Format query results into list of dictionaries"""
        if not fields or not result:
            return []
        field_names = [field[0] for field in fields]
        return [dict(zip(field_names, row)) for row in result]

class BaseCheck:
    def __init__(self, host="", port=9030, user="", passwd="", db="", mode="shared_nothing"):
        self.table_black_list = ['information_schema', '_statistics_', 'starrocks_monitor']
        self.db = DbHandler(host=host, port=port, user=user, passwd=passwd, db=db)
        self.mode = mode

    def convert_size(self, size_str):
        """Convert size string to bytes"""
        if not size_str:
            return 0
        try:
            # 纯数字直接返回字节数
            if size_str.replace('.', '', 1).isdigit():
                return float(size_str)
            # 正则提取数值和单位
            match = re.match(r'([0-9.]+)\s*([A-Za-z]+)', size_str)
            if match:
                num, unit = match.groups()
                unit = unit.upper()
                capacity_dict = {
                    "B": 1,
                    "KB": 1024,
                    "MB": 1024 * 1024,
                    "GB": 1024 * 1024 * 1024,
                    "TB": 1024 * 1024 * 1024 * 1024,
                    "PB": 1024 * 1024 * 1024 * 1024 * 1024
                }
                if unit in capacity_dict:
                    return float(num) * capacity_dict[unit]
        except Exception as e:
            print(f"convert_size error: {e}, input: {size_str}")
        return 0

    def get_all_dbs(self):
        """Get all databases"""
        fields, result = self.db.query("SHOW PROC '/dbs'")
        if not result:
            return {}
            
        dbs_sets_valid = {}
        for db in result:
            db_name = db[1].split(':')[1] if ':' in db[1] else db[1]
            dbs_sets_valid[db_name] = db[0]
        return dbs_sets_valid

    def get_db_tables(self, databases=None):
        """Get tables for specified databases"""
        valid_tables = {}
        dbs_sets = self.get_all_dbs()
        valid_dbs = databases if databases else dbs_sets.keys()

        for db in valid_dbs:
            if db in self.table_black_list or db not in dbs_sets:
                if db not in dbs_sets:
                    print(f"\033[31mDatabase {db} not found.\033[0m")
                continue

            fields, result = self.db.query(f"SHOW PROC '/dbs/{dbs_sets[db]}'")
            if not result:
                continue

            tables_info = self.db.format(fields, result)
            valid_tables[db] = [
                table['TableName'] for table in tables_info 
                if table['Type'] in ("OLAP", "CLOUD_NATIVE")
            ]

        return valid_tables

    def get_table_info(self, db, table, replica, bucket, debug):
        """Get table information including partitions and replicas"""
        sql = f"show partitions from `{db}`.`{table}`;"
        if debug:
            print(f"DEBUG get_table_info sql is {sql}")

        fields, result = self.db.query(sql)
        if not result:
            return None

        info = {
            "replica_counts": 0,
            "data_size": 0,
            "replica_partition": [],
            "bucket_partitions": [],
            "null_partitions": []
        }

        try:
            for row in self.db.format(fields, result):
                if self.mode == RUN_MODE:
                    if int(row['ReplicationNum']) == replica:
                        info["replica_partition"].append(row['PartitionName'])
                    info["replica_counts"] += int(row['ReplicationNum']) * int(row['Buckets'])
                else:
                    info["replica_counts"] += int(row['Buckets'])

                if int(row['Buckets']) == bucket:
                    info["bucket_partitions"].append(row['PartitionName'])

                data_size = self.convert_size(row['DataSize'])
                if not data_size:
                    info["null_partitions"].append(row['PartitionName'])
                else:
                    info["data_size"] += data_size

            return info
        except Exception as e:
            print(f"\033[31mFailed to get partitions of {db}.{table}: {e}\033[0m")
            return None

    def get_tablet_info(self, db, table, debug):
        """Get tablet information"""
        sql = f"show tablet from `{db}`.`{table}`;"
        if debug:
            print(f"DEBUG get_tablet_info sql is {sql}")

        fields, result = self.db.query(sql)
        if not result:
            return np.array([])

        tablet_list = [
            self.convert_size(line['DataSize']) 
            for line in self.db.format(fields, result) 
            if self.convert_size(line['DataSize']) > 0
        ]
        return np.array(tablet_list) if tablet_list else np.array([])

    def get_table_schema(self, db, table, debug):
        """Get table schema"""
        sql = f"show create table `{db}`.`{table}`;"
        if debug:
            print(f"DEBUG get_table_schema sql is {sql}")

        fields, result = self.db.query(sql)
        return result[0] if result else None

    def replica_healthy(self, replica, bucket, debug):
        """Check replica health status"""
        tables_info = []
        db_tables = self.get_db_tables([])
        
        for count, (db, tables) in enumerate(db_tables.items(), 1):
            if count != len(db_tables):
                print(f"In progress............{count}/{len(db_tables)}")

            for table in tables:
                if not table:
                    continue

                table_info = self.get_table_info(db, table, replica, bucket, debug)
                if not table_info or not table_info["replica_counts"]:
                    continue

                schema = False
                table_schema = self.get_table_schema(db, table, debug)
                if table_schema:
                    schema = bool(re.search(rf'"replication_num" = "{replica}"', 
                                          table_schema[-1], re.M | re.I))

                tablet_array = self.get_tablet_info(db, table, debug)
                sqrt = 0.0
                if not (table_info["replica_counts"] == 1 or 
                       tablet_array.shape in ((0,), (1,))):
                    sqrt = np.sqrt(np.var(tablet_array, ddof=1))

                # 保留原始的 replica_partitions，不去掉空分区
                replica_partitions = table_info["replica_partition"]
                print(round(table_info["data_size"]/1024/1024, 2))


                tables_info.append({
                    "db_name": db,
                    "tb_name": table,
                    "data_size": round(table_info["data_size"]/1024/1024, 2),
                    "replica_counts": table_info["replica_counts"],
                    "mean": round(table_info["data_size"]/table_info["replica_counts"]/1024/1024, 2) if table_info["replica_counts"] > 0 else 0.0,
                    "sqrt": round(sqrt/1024/1024, 2),
                    "replica_partitions": replica_partitions,
                    "bucket_partitions": table_info["bucket_partitions"],
                    "null_partitions": table_info["null_partitions"],
                    "is_schema": schema
                })

        return tables_info

def get_tables_info(host, port, user, password, mode, replica, bucket, debug):
    """Get tables information using provided connection parameters"""
    if mode != "shared_nothing":
        global RUN_MODE
        RUN_MODE = "shared_data"

    base_check = BaseCheck(
        user=user,
        host=host,
        db='_statistics_',
        port=port,
        passwd=password,
        mode=mode
    )
    return base_check.replica_healthy(replica, bucket, debug)

def format_tables_to_json(tables):
    """Convert tables data to JSON format"""
    return json.dumps(tables, indent=2, ensure_ascii=False)

def format_tables_to_yaml(tables):
    """Convert tables data to YAML format"""
    return yaml.dump(tables, allow_unicode=True, sort_keys=False)

def format_tables_to_table(tables):
    """Convert tables data to table format"""
    table_format = PrettyTable([
        'database_name', 'table_name', 'datasize of table(/MB)',
        'replica_counts', 'avg of tablet datasize(/MB)',
        'standard deviation of tablet datasize', 'empty partition tablets count'
    ])
    
    for table in sorted(tables, key=lambda i: (i['replica_counts'], i['db_name'], i['tb_name']), reverse=True):
        # Calculate mean using data_size/replica_counts for consistency
        mean_size = round(table['data_size']/table['replica_counts'], 2) if table['replica_counts'] > 0 else 0.0
        table_format.add_row([
            table['db_name'], table['tb_name'], table['data_size'],
            table['replica_counts'], mean_size, table['sqrt'],
            len(table['null_partitions'])
        ])
    return str(table_format)

def save_to_file(data, output_file, format_type):
    """Save data to file in specified format"""
    try:
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(data)
        print(f"Data has been saved to {output_file}")
    except Exception as e:
        print(f"Error saving to file: {e}")

def get_output_filename(base_dir, module_name, format_type):
    """Generate output filename with timestamp and module name"""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    os.makedirs(base_dir, exist_ok=True)
    return os.path.join(base_dir, f'health_report_{module_name}_{timestamp}.{format_type}')

def print_health_report(tables, output_format='table', output_dir='./reports'):
    """Save health report in specified format"""
    if output_format == 'json':
        data = format_tables_to_json(tables)
    elif output_format == 'yaml':
        data = format_tables_to_yaml(tables)
    else:  # table format
        data = format_tables_to_table(tables)
    
    # Save to file
    output_file = get_output_filename(output_dir, 'tablets', output_format)
    save_to_file(data, output_file, output_format)

def print_replica_info(tables, replica, output_format='table', output_dir='./reports'):
    """Save replica information in specified format"""
    replica_data = []
    for table in sorted(tables, key=lambda i: (i['db_name'], i['tb_name']), reverse=True):
        if table["replica_partitions"]:
            table_name = f"{table['tb_name']}(schema is {replica} replica)" if table['is_schema'] else table['tb_name']
            replica_data.append({
                'database_name': table['db_name'],
                'table_name': table_name,
                'partitions_count': len(table["replica_partitions"]),
                'partitions': table["replica_partitions"]
            })

    if output_format == 'json':
        data = json.dumps(replica_data, indent=2, ensure_ascii=False)
    elif output_format == 'yaml':
        data = yaml.dump(replica_data, allow_unicode=True, sort_keys=False)
    else:  # table format
        table_format = PrettyTable([
            'database_name', 'table_name', 'the number of partitions',
            f'partitions of {replica} replica'
        ])
        for item in replica_data:
            table_format.add_row([
                item['database_name'], item['table_name'],
                item['partitions_count'],
                ','.join(item['partitions'])
            ])
        data = str(table_format)

    # Save to file
    output_file = get_output_filename(output_dir, 'replicas', output_format)
    save_to_file(data, output_file, output_format)

def print_bucket_info(tables, bucket, output_format='table', output_dir='./reports'):
    """Save bucket information in specified format"""
    bucket_data = []
    for table in sorted(tables, key=lambda i: (i['db_name'], i['tb_name']), reverse=True):
        if table['bucket_partitions']:
            bucket_data.append({
                'database_name': table['db_name'],
                'table_name': table['tb_name'],
                'partitions_count': len(table["bucket_partitions"]),
                'partitions': table["bucket_partitions"]
            })

    if output_format == 'json':
        data = json.dumps(bucket_data, indent=2, ensure_ascii=False)
    elif output_format == 'yaml':
        data = yaml.dump(bucket_data, allow_unicode=True, sort_keys=False)
    else:  # table format
        table_format = PrettyTable([
            'database_name', 'table_name', 'the number of partitions',
            f'partitions of {bucket} bucket'
        ])
        for item in bucket_data:
            table_format.add_row([
                item['database_name'], item['table_name'],
                item['partitions_count'],
                ','.join(item['partitions'])
            ])
        data = str(table_format)

    # Save to file
    output_file = get_output_filename(output_dir, 'buckets', output_format)
    save_to_file(data, output_file, output_format)

def print_partitions_info(tables, partition_size, output_format='table', output_dir='./reports'):
    """Save partition information in specified format"""
    partition_data = []
    for table in sorted(tables, key=lambda i: (i['db_name'], i['tb_name']), reverse=True):
        if table['null_partitions']:
            partition_data.append({
                'database_name': table['db_name'],
                'table_name': table['tb_name'],
                'null_partitions_count': len(table['null_partitions']),
                'null_partitions': table['null_partitions']
            })

    if output_format == 'json':
        data = json.dumps(partition_data, indent=2, ensure_ascii=False)
    elif output_format == 'yaml':
        data = yaml.dump(partition_data, allow_unicode=True, sort_keys=False)
    else:  # table format
        table_format = PrettyTable([
            'database_name', 'table_name', 'the number of null partitions',
            'null partitions'
        ])
        for item in partition_data:
            table_format.add_row([
                item['database_name'], item['table_name'],
                item['null_partitions_count'],
                '\\n'.join([', '.join(item['null_partitions'][i:i+5]) for i in range(0, len(item['null_partitions']), 5)])
            ])
        data = str(table_format)

    # Save to file
    output_file = get_output_filename(output_dir, 'partitions', output_format)
    save_to_file(data, output_file, output_format)

def main():
    parser = argparse.ArgumentParser(description='StarRocks Health Report Tool')
    parser.add_argument('--host', type=str, required=True, help='FE host address')
    parser.add_argument('--port', type=int, required=True, help='FE query port')
    parser.add_argument('--user', type=str, required=True, help='Database user')
    parser.add_argument('--password', type=str, required=True, help='Database password')
    parser.add_argument('--mode', type=str, default='shared_nothing', 
                      choices=['shared_nothing', 'shared_data'],
                      help='Cluster mode')
    parser.add_argument('--replica', type=int, default=1, help='replica number')
    parser.add_argument('--bucket', type=int, default=1, help='bucket number')
    parser.add_argument('--partition_size', type=int, default=0, help='partition size')
    parser.add_argument('--module', type=str, default='all',
                      choices=['all', 'buckets', 'tablets', 'partitions', 'replicas'],
                      help='Module to run')
    parser.add_argument('--debug', action='store_true', help='Enable debug mode')
    parser.add_argument('--format', type=str, default='table',
                      choices=['table', 'json', 'yaml'],
                      help='Output format')
    parser.add_argument('--output-dir', type=str, default='./reports',
                      help='Output directory for reports')
    args = parser.parse_args()

    try:
        tables = get_tables_info(
            host=args.host,
            port=args.port,
            user=args.user,
            password=args.password,
            mode=args.mode,
            replica=args.replica,
            bucket=args.bucket,
            debug=args.debug
        )

        if args.module in ("all", "tablets"):
            print_health_report(tables, args.format, args.output_dir)

        if args.mode == "shared_nothing":
            if args.module in ("all", "replicas"):
                print_replica_info(tables, args.replica, args.format, args.output_dir)
        elif args.module == "replicas":
            print("Shard_data do not need check single replica tables.")

        if args.module in ("all", "buckets") and args.bucket != 0:
            print_bucket_info(tables, args.bucket, args.format, args.output_dir)

        if args.module in ("all", "partitions"):
            if args.partition_size != 0:
                print("Only support check null partitions now.")
            else:
                print_partitions_info(tables, args.partition_size, args.format, args.output_dir)

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
