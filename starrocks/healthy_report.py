# -*- coding: utf-8 -*-

import re
import sys
import argparse

sys.path.append("../")
from starrocks.utils import db_handler
from prettytable import PrettyTable
import numpy as np

np.seterr(invalid='ignore')

import configparser

def Parser(file_name):
    commonConf = {}
    conf = configparser.ConfigParser()
    conf.read(file_name, encoding='utf-8')
    sections = conf.sections()
    for section in sections:
        commonConf[section] = dict(conf.items(section))
    return commonConf

class BaseCheck(object):

    def __init__(self, host="", port=9030, user="", passwd="", db=""):
        self.table_black_list = []
        self.db = db_handler.DbHanlder(host=host, port=port,
                                       user=user, passwd=passwd, db=db)
        self.db.open()

    def convert(self, item):
        capacity_dict = {
            "B": 1,
            "KB": 1 * 1024,
            "MB": 1 * 1024 * 1024,
            "GB": 1 * 1024 * 1024 * 1024,
            "TB": 1 * 1024 * 1024 * 1024 * 1024,
            "PB": 1 * 1024 * 1024 * 1024 * 1024
        }
        if 'PB' in item:
            data_size_format = float(item.split('PB')[0].strip())
            return capacity_dict['PB'] * data_size_format
        elif 'TB' in item:
            data_size_format = float(item.split('TB')[0].strip())
            return capacity_dict['TB'] * data_size_format
        elif 'GB' in item:
            data_size_format = float(item.split('GB')[0].strip())
            return capacity_dict['GB'] * data_size_format
        elif 'MB' in item:
            data_size_format = float(item.split('MB')[0].strip())
            return capacity_dict['MB'] * data_size_format
        elif 'KB' in item:
            data_size_format = float(item.split('KB')[0].strip())
            return capacity_dict['KB'] * data_size_format
        else:
            data_size_format = float(item.split('B')[0].strip())
            return capacity_dict['B'] * data_size_format

    def get_dbs(self, dbs):
        dbs_sets_valid = []
        sql = "SHOW PROC '/dbs';"
        dbs_sets = self.db.query(sql)[1]
        if len(dbs):
            dbs_sets_valid = [(db[0], db[1].split(':')[1]) for db in dbs_sets
                              if db[1].split(':')[1] in dbs]
        else:
            dbs_sets_valid = [(db[0], db[1].split(':')[1]) for db in dbs_sets]
        return dbs_sets_valid

    def get_db_tables(self, databases):
        valid_tables = {}
        dbs_sets = self.get_dbs(databases)
        for db_set in dbs_sets:
            sql = "SHOW PROC '/dbs/%s'" % db_set[0]
            fields, result = self.db.query(sql)
            tables_info = self.db.format(fields, result)
            for table in tables_info:
                if table['Type'] == "OLAP":
                    if db_set[1] in valid_tables:
                        valid_tables[db_set[1]].append(table['TableName'])
                    else:
                        valid_tables[db_set[1]] = [table['TableName']]
        return valid_tables

    def get_table_info(self, db, table, replica):
        replica_partitions = []
        replica_counts = 0
        data_size = 0
        sql = "show partitions from %s.%s;" % (db, table)
        fields, result = self.db.query(sql)
        infos = self.db.format(fields, result)
        for row in infos:
            if int(row['ReplicationNum']) == replica:
                replica_partitions.append(row['PartitionName'])
            if not row['DataSize']:
                data_size += 0
            else:
                data_size += self.convert(row['DataSize'])
            replica_counts += int(row['ReplicationNum'])*int(row['Buckets'])
        return {
            "replica_counts": replica_counts,
            "data_size": data_size,
            "replica_partition": replica_partitions
        }

    def get_tablet_info(self, db, table):
        sql = "show tablet from %s.%s;" % (db, table)
        fields, infos = self.db.query(sql)
        result = self.db.format(fields, infos)
        tablet_data_array = np.array([self.convert(line['DataSize']) for line in result])
        return tablet_data_array

    def get_table_schema(self, db, table):
        sql = "show create table %s.%s;" % (db, table)
        infos = self.db.query(sql)
        return infos[1][0]

    def table_healthy(self, replica, databases):
        schema = False
        count = 0
        tables_info = []
        db_tables = self.get_db_tables(databases)
        db_nums = len(db_tables)
        for db in db_tables.keys():
            count += 1
            if count != db_nums:
                print("In progress............{}/{}".format(count, db_nums))
            for table in db_tables[db]:
                if table in self.table_black_list:
                    continue
                if not table:
                    continue
                table_info = self.get_table_info(db, table, replica)
                if not table_info["replica_counts"]:
                    continue
                table_schema = self.get_table_schema(db, table)[-1]
                matchObj = re.search(r'"replication_num" = "{}"'.format(replica),
                                     table_schema, re.M | re.I)
                if matchObj:
                    schema = True

                data_size = table_info["data_size"]
                replica_counts = table_info["replica_counts"]
                tablet_array = self.get_tablet_info(db, table)
                if replica_counts == 1:
                    sqrt = 0.0
                else:
                    sqrt = np.sqrt(np.var(tablet_array, ddof=1))
                tables_info.append({
                    "db_name": db,
                    "tb_name": table,
                    "data_size": round(data_size/1024/1024, 2),
                    "replica_counts": replica_counts,
                    "mean": round(np.mean(tablet_array)/1024/1024, 2),
                    "sqrt": round(sqrt/1024/1024, 2),
                    "replica_partitions": table_info["replica_partition"],
                    "is_schema": schema
                })
        return tables_info



def get_tables_info(conf, replica):
    config = Parser(conf)['common']
    databases = config['databases'].split(',')
    if databases != ['']:
        dbs = databases
    else:
        dbs = []
    base_check = BaseCheck(user=config['user'], host=config['fe_host'],
                               db='_statistics_', port=int(config['fe_query_port']), passwd=config['password'])
    tables = base_check.table_healthy(replica, dbs)
    return tables

def print_health_report(tables):
    table_format = PrettyTable(['database_name', 'table_name', 'datasize of table(/MB)', 'replica_counts',
                                'avg of tablet datasize(/MB)', 'standard deviation of tablet datasize'])
    tables_info = sorted(tables, key=lambda i: (i['db_name'], i['tb_name']), reverse=True)
    for table in tables_info:
       table_format.add_row([table['db_name'], table['tb_name'], table['data_size'],
                             table['replica_counts'], table['mean'], table['sqrt']])
    print(table_format)

def print_tablet_info(tables, replica):
    tables_info = sorted(tables, key=lambda i: (i['db_name'], i['tb_name']), reverse=True)
    single_table_format = PrettyTable(['database_name', 'table_name', 'partition of {} replica'.format(replica)])
    for table in tables_info:
        if table['is_schema']:
            for pt in table["replica_partitions"]:
                single_table_format.add_row([table['db_name'],
                                             table['tb_name']+"(schema is {} replica)".format(replica), pt])
        else:
            for pt in table["replica_partitions"]:
                single_table_format.add_row([table['db_name'], table['tb_name'], pt])
    print(single_table_format)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='replication number')
    parser.add_argument('config', type=str, help='config.ini')
    parser.add_argument('replica', type=int, nargs='?', default=1, help='replication number')
    args = parser.parse_args()

    tables = get_tables_info(args.config, args.replica)

    print_health_report(tables)

    print_tablet_info(tables, args.replica)
