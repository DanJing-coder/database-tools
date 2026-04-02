# -*- coding: utf-8 -*-

import sys
import argparse
import pymysql
from datetime import datetime

# 还不够好用，性能不好，待优化

class ConfigBackup:
    def __init__(self, host, port=9030, user="root", password="", module="bf"):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.module = module
        self.date = datetime.now().strftime("%Y%m%d")
        self.db_handler = None
        self.database = "up_cluster_bak"
        self.starrocks_version = None
        self.is_version_3_or_higher = False
        self.is_version_2_5 = False
        
        # 根据模块类型决定表名
        if module == "df":
            # 比较模式，设置变更记录表名
            self.be_change_table = f"be_configs_change_{self.date}"
            self.fe_change_table = f"fe_configs_change_{self.date}"
            self.vars_change_table = f"variables_change_{self.date}"
            # 新增/删除配置表名
            self.be_add_drop_table = f"be_configs_add_drop_{self.date}"
            self.fe_add_drop_table = f"fe_configs_add_drop_{self.date}"
            self.vars_add_drop_table = f"variables_add_drop_{self.date}"
        else:
            # 备份模式，根据模块类型决定表名前缀
            prefix = "after" if module == "af" else "before"
            self.be_table_name = f"be_configs_{prefix}_{self.date}"
            self.fe_table_name = f"fe_configs_{prefix}_{self.date}"
            self.vars_table_name = f"variables_{prefix}_{self.date}"

    def connect(self):
        """建立数据库连接"""
        try:
            self.db_handler = pymysql.connect(
                host=self.host,
                user=self.user,
                password=self.password,
                port=self.port,
                charset="utf8",
                cursorclass=pymysql.cursors.DictCursor
            )
            print(f"成功连接到StarRocks集群: {self.host}:{self.port}")
            # 连接成功后获取版本信息
            self.get_starrocks_version()
        except Exception as e:
            print(f"连接失败: {e}")
            sys.exit(1)
            
    def get_starrocks_version(self):
        """获取StarRocks版本信息并设置版本标记"""
        try:
            sql = "SELECT current_version() AS version"
            result = self.execute_query(sql)
            if result and 'version' in result[0]:
                self.starrocks_version = result[0]['version']
                print(f"StarRocks版本: {self.starrocks_version}")
                
                # 检测版本类型
                if self.starrocks_version.startswith('3'):
                    self.is_version_3_or_higher = True
                elif self.starrocks_version.startswith('2.5'):
                    self.is_version_2_5 = True
        except Exception as e:
            print(f"获取版本信息失败: {e}")

    def disconnect(self):
        """关闭数据库连接"""
        if self.db_handler:
            self.db_handler.close()
            print("数据库连接已关闭")

    def execute_query(self, sql, params=None, fetch_result=True):
        """执行SQL查询并返回结果"""
        cursor = self.db_handler.cursor()
        try:
            cursor.execute(sql, params or ())
            if fetch_result:
                result = cursor.fetchall()
                return result
            self.db_handler.commit()
            return True
        except Exception as e:
            print(f"执行SQL失败: {sql}\n错误: {e}")
            self.db_handler.rollback()
            return None
        finally:
            cursor.close()

    def check_database_exists(self):
        """检查数据库是否存在，不存在则创建"""
        sql = f"SHOW DATABASES LIKE '{self.database}'"
        result = self.execute_query(sql)
        if not result:
            print(f"创建数据库: {self.database}")
            create_db_sql = f"CREATE DATABASE IF NOT EXISTS {self.database}"
            return self.execute_query(create_db_sql, fetch_result=False)
        return True

    def check_table_exists(self, table_name):
        """检查表是否存在"""
        sql = f"SHOW TABLES FROM {self.database} LIKE '{table_name}'"
        result = self.execute_query(sql)
        return len(result) > 0

    def create_be_table(self):
        """创建BE配置表"""
        if not self.check_table_exists(self.be_table_name):
            print(f"创建BE配置表: {self.database}.{self.be_table_name}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.be_table_name}` (
               `be_id` bigint(20) NULL COMMENT "", 
               `name` varchar(2048) NULL COMMENT "", 
               `value` varchar(2048) NULL COMMENT "", 
               `type` varchar(2048) NULL COMMENT "", 
               `default` varchar(2048) NULL COMMENT "", 
               `mutable` boolean NULL COMMENT "" 
             ) ENGINE=OLAP 
             DUPLICATE KEY(`be_id`, `name`) 
             COMMENT "OLAP" 
             DISTRIBUTED BY HASH(`be_id`) BUCKETS 10 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True

    def create_fe_table(self):
        """创建FE配置表"""
        if not self.check_table_exists(self.fe_table_name):
            print(f"创建FE配置表: {self.database}.{self.fe_table_name}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.fe_table_name}` (
               `key` varchar(2028) NULL COMMENT "", 
               `aliasnames` varchar(2028) NULL COMMENT "", 
               `value` varchar(2028) NULL COMMENT "", 
               `type` varchar(2028) NULL COMMENT "", 
               `ismutable` varchar(2028) NULL COMMENT "", 
               `comment` varchar(2028) NULL COMMENT "" 
             ) ENGINE=OLAP 
             DUPLICATE KEY(`key`) 
             COMMENT "fe.conf 配置信息表" 
             DISTRIBUTED BY HASH(`key`) BUCKETS 8 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True

    def create_vars_table(self):
        """创建variables表"""
        if not self.check_table_exists(self.vars_table_name):
            print(f"创建variables表: {self.database}.{self.vars_table_name}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.vars_table_name}` (
               `variable_name` varchar(2028) NULL COMMENT "", 
               `value` varchar(2028) NULL COMMENT "" 
             ) ENGINE=OLAP 
             DUPLICATE KEY(`variable_name`) 
             COMMENT "variables表" 
             DISTRIBUTED BY HASH(`variable_name`) BUCKETS 8 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True
    
    def create_be_change_table(self):
        """创建BE配置变更表"""
        if not self.check_table_exists(self.be_change_table):
            print(f"创建BE配置变更表: {self.database}.{self.be_change_table}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.be_change_table}` (
               `be_id` bigint(20) NULL COMMENT "", 
               `name` varchar(2048) NULL COMMENT "", 
               `before_value` varchar(2048) NULL COMMENT "升级前值", 
               `after_value` varchar(2048) NULL COMMENT "升级后值", 
               `type` varchar(2048) NULL COMMENT "", 
               `default` varchar(2048) NULL COMMENT "", 
               `mutable` boolean NULL COMMENT "" 
             ) ENGINE=OLAP 
             DUPLICATE KEY(`be_id`, `name`) 
             COMMENT "BE配置变更表" 
             DISTRIBUTED BY HASH(`be_id`) BUCKETS 10 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True
    
    def create_fe_change_table(self):
        """创建FE配置变更表"""
        if not self.check_table_exists(self.fe_change_table):
            print(f"创建FE配置变更表: {self.database}.{self.fe_change_table}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.fe_change_table}` (
               `key` varchar(2028) NULL COMMENT "", 
               `aliasnames` varchar(2028) NULL COMMENT "", 
               `before_value` varchar(2028) NULL COMMENT "升级前值", 
               `after_value` varchar(2028) NULL COMMENT "升级后值", 
               `type` varchar(2028) NULL COMMENT "", 
               `ismutable` varchar(2028) NULL COMMENT "", 
               `comment` varchar(2028) NULL COMMENT "" 
             ) ENGINE=OLAP 
             DUPLICATE KEY(`key`) 
             COMMENT "FE配置变更表" 
             DISTRIBUTED BY HASH(`key`) BUCKETS 8 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True
    
    def create_vars_change_table(self):
        """创建variables变更表"""
        if not self.check_table_exists(self.vars_change_table):
            print(f"创建variables变更表: {self.database}.{self.vars_change_table}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.vars_change_table}` (
               `variable_name` varchar(2028) NULL COMMENT "", 
               `before_value` varchar(2028) NULL COMMENT "升级前值", 
               `after_value` varchar(2028) NULL COMMENT "升级后值" 
             ) ENGINE=OLAP 
             DUPLICATE KEY(`variable_name`) 
             COMMENT "variables变更表" 
             DISTRIBUTED BY HASH(`variable_name`) BUCKETS 8 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True
    
    def create_be_add_drop_table(self):
        """创建BE新增/删除配置表"""
        if not self.check_table_exists(self.be_add_drop_table):
            print(f"创建BE新增/删除配置表: {self.database}.{self.be_add_drop_table}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.be_add_drop_table}` (
               `be_id` bigint(20) NULL COMMENT "", 
               `name` varchar(2048) NULL COMMENT "", 
               `value` varchar(2048) NULL COMMENT "", 
               `type` varchar(2048) NULL COMMENT "", 
               `default` varchar(2048) NULL COMMENT "", 
               `mutable` boolean NULL COMMENT "",
               `change_type` varchar(20) NULL COMMENT "变更类型:新增/删除"
             ) ENGINE=OLAP 
             DUPLICATE KEY(`be_id`, `name`) 
             COMMENT "BE新增/删除配置表" 
             DISTRIBUTED BY HASH(`be_id`) BUCKETS 10 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True
    
    def create_fe_add_drop_table(self):
        """创建FE新增/删除配置表"""
        if not self.check_table_exists(self.fe_add_drop_table):
            print(f"创建FE新增/删除配置表: {self.database}.{self.fe_add_drop_table}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.fe_add_drop_table}` (
               `key` varchar(2028) NULL COMMENT "", 
               `aliasnames` varchar(2028) NULL COMMENT "", 
               `value` varchar(2028) NULL COMMENT "", 
               `type` varchar(2028) NULL COMMENT "", 
               `ismutable` varchar(2028) NULL COMMENT "", 
               `comment` varchar(2028) NULL COMMENT "",
               `change_type` varchar(20) NULL COMMENT "变更类型:新增/删除"
             ) ENGINE=OLAP 
             DUPLICATE KEY(`key`) 
             COMMENT "FE新增/删除配置表" 
             DISTRIBUTED BY HASH(`key`) BUCKETS 8 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True
    
    def create_vars_add_drop_table(self):
        """创建variables新增/删除表"""
        if not self.check_table_exists(self.vars_add_drop_table):
            print(f"创建variables新增/删除表: {self.database}.{self.vars_add_drop_table}")
            create_sql = f"""CREATE TABLE `{self.database}`.`{self.vars_add_drop_table}` (
               `variable_name` varchar(2028) NULL COMMENT "", 
               `value` varchar(2028) NULL COMMENT "",
               `change_type` varchar(20) NULL COMMENT "变更类型:新增/删除"
             ) ENGINE=OLAP 
             DUPLICATE KEY(`variable_name`) 
             COMMENT "variables新增/删除表" 
             DISTRIBUTED BY HASH(`variable_name`) BUCKETS 8 
             PROPERTIES ( 
               "replication_num" = "1" 
             )"""
            return self.execute_query(create_sql, fetch_result=False)
        return True

    def backup_be_configs(self):
        """备份BE配置信息，根据StarRocks版本区分处理逻辑"""
        # 检查information_schema.be_configs表是否存在
        check_sql = "SHOW TABLES FROM information_schema LIKE 'be_configs'"
        result = self.execute_query(check_sql)
        if not result:
            print("information_schema.be_configs表不存在，跳过BE配置备份")
            return

        # 获取BE配置信息
        print("获取BE配置信息...")
        
        # 根据版本选择不同的查询SQL
        if self.is_version_3_or_higher:
            # 3开头版本使用完整字段
            sql = "SELECT be_id,name,value,type,`default`,mutable FROM information_schema.be_configs WHERE be_id = '354422396'"
        elif self.is_version_2_5:
            # 2.5开头版本只有be_id、name、value三列
            sql = "SELECT be_id,name,value FROM information_schema.be_configs WHERE be_id = '354422396'"
        else:
            # 默认使用完整字段
            sql = "SELECT be_id,name,value,type,`default`,mutable FROM information_schema.be_configs WHERE be_id = '354422396'"
            
        be_configs = self.execute_query(sql)
        if not be_configs:
            print("未获取到BE配置信息")
            return

        # 创建表
        if not self.create_be_table():
            print("创建BE配置表失败")
            return

        # 插入数据
        print(f"备份BE配置信息到 {self.database}.{self.be_table_name}")
        
        if self.is_version_3_or_higher:
            # 3开头版本插入所有字段
            insert_sql = f"""INSERT INTO `{self.database}`.`{self.be_table_name}` 
                            (be_id, name, value, type, `default`, mutable) 
                            VALUES (%s, %s, %s, %s, %s, %s)"""
        elif self.is_version_2_5:
            # 2.5开头版本只插入三列，其他列设为默认值
            insert_sql = f"""INSERT INTO `{self.database}`.`{self.be_table_name}` 
                            (be_id, name, value, type, `default`, mutable) 
                            VALUES (%s, %s, %s, '', '', false)"""
        else:
            # 默认插入所有字段
            insert_sql = f"""INSERT INTO `{self.database}`.`{self.be_table_name}` 
                            (be_id, name, value, type, `default`, mutable) 
                            VALUES (%s, %s, %s, %s, %s, %s)"""
        
        cursor = self.db_handler.cursor()
        try:
            for config in be_configs:
                if self.is_version_3_or_higher or not self.is_version_2_5:
                    # 3开头版本或其他版本插入所有字段
                    cursor.execute(insert_sql, (
                        config['be_id'],
                        config['name'],
                        config['value'],
                        config.get('type', ''),
                        config.get('default', ''),
                        config.get('mutable', False)
                    ))
                else:
                    # 2.5开头版本只插入三列
                    cursor.execute(insert_sql, (
                        config['be_id'],
                        config['name'],
                        config['value']
                    ))
            self.db_handler.commit()
            print(f"成功备份{len(be_configs)}条BE配置信息")
        except Exception as e:
            print(f"备份BE配置信息失败: {e}")
            self.db_handler.rollback()
        finally:
            cursor.close()

    def backup_fe_configs(self):
        """备份FE配置信息"""
        # 获取FE配置信息
        print("获取FE配置信息...")
        sql = "ADMIN SHOW FRONTEND CONFIG"
        fe_configs = self.execute_query(sql)
        if not fe_configs:
            print("未获取到FE配置信息")
            return
        
        # 将字段名转换为小写
        lowercase_fe_configs = []
        for config in fe_configs:
            lowercase_config = {k.lower(): v for k, v in config.items()}
            lowercase_fe_configs.append(lowercase_config)
        fe_configs = lowercase_fe_configs

        # 创建表
        if not self.create_fe_table():
            print("创建FE配置表失败")
            return

        # 插入数据
        print(f"备份FE配置信息到 {self.database}.{self.fe_table_name}")
        insert_sql = f"""INSERT INTO `{self.database}`.`{self.fe_table_name}` 
                        (`key`, aliasNames, value, `type`, isMutable, `comment`) 
                        VALUES (%s, %s, %s, %s, %s, %s)"""
        cursor = self.db_handler.cursor()
        try:
            for config in fe_configs:
                cursor.execute(insert_sql, (
                    config.get('key', ''),
                    config.get('aliasNames', ''),
                    config.get('value', ''),
                    config.get('type', ''),
                    config.get('isMutable', ''),
                    config.get('comment', '')
                ))
            self.db_handler.commit()
            print(f"成功备份{len(fe_configs)}条FE配置信息")
        except Exception as e:
            print(f"备份FE配置信息失败: {e}")
            self.db_handler.rollback()
        finally:
            cursor.close()

    def backup_variables(self):
        """备份variables信息"""
        # 获取variables信息
        print("获取variables信息...")
        sql = "SHOW VARIABLES"
        variables = self.execute_query(sql)
        if not variables:
            print("未获取到variables信息")
            return

        # 创建表
        if not self.create_vars_table():
            print("创建variables表失败")
            return

        # 插入数据
        print(f"备份variables信息到 {self.database}.{self.vars_table_name}")
        insert_sql = f"""INSERT INTO `{self.database}`.`{self.vars_table_name}` 
                        (variable_name, value) 
                        VALUES (%s, %s)"""
        cursor = self.db_handler.cursor()
        try:
            for var in variables:
                cursor.execute(insert_sql, (
                    var.get('Variable_name', var.get('variable_name', '')),
                    var.get('Value', var.get('value', ''))
                ))
            self.db_handler.commit()
            print(f"成功备份{len(variables)}条variables信息")
        except Exception as e:
            print(f"备份variables信息失败: {e}")
            self.db_handler.rollback()
        finally:
            cursor.close()

    def compare_be_configs(self):
        """比较BE配置变更并存储变更信息，根据StarRocks版本区分处理逻辑"""
        # 检查BE配置表是否存在
        before_table = f"be_configs_before_{self.date}"
        after_table = f"be_configs_after_{self.date}"
        
        if not self.check_table_exists(before_table):
            print(f"BE配置升级前表 {self.database}.{before_table} 不存在")
            return
        
        if not self.check_table_exists(after_table):
            print(f"BE配置升级后表 {self.database}.{after_table} 不存在")
            return
        
        # 获取变更信息
        print("比较BE配置变更...")
        
        # 根据版本选择不同的查询SQL
        if self.is_version_3_or_higher:
            # 3开头版本比较所有字段
            sql = f"""SELECT b.be_id, b.name, b.value as before_value, a.value as after_value, b.type, b.`default`, b.mutable
                     FROM `{self.database}`.{before_table} b
                     JOIN `{self.database}`.{after_table} a ON b.be_id = a.be_id AND b.name = a.name
                     WHERE b.value != a.value"""
        elif self.is_version_2_5:
            # 2.5开头版本只比较三列
            sql = f"""SELECT b.be_id, b.name, b.value as before_value, a.value as after_value
                     FROM `{self.database}`.{before_table} b
                     JOIN `{self.database}`.{after_table} a ON b.be_id = a.be_id AND b.name = a.name
                     WHERE b.value != a.value"""
        else:
            # 默认比较所有字段
            sql = f"""SELECT b.be_id, b.name, b.value as before_value, a.value as after_value, b.type, b.`default`, b.mutable
                     FROM `{self.database}`.{before_table} b
                     JOIN `{self.database}`.{after_table} a ON b.be_id = a.be_id AND b.name = a.name
                     WHERE b.value != a.value"""
        
        changes = self.execute_query(sql)
        if not changes:
            print("未发现BE配置变更")
        else:
            # 创建变更表
            if not self.create_be_change_table():
                print("创建BE配置变更表失败")
                return
            
            # 插入变更数据
            print(f"存储BE配置变更信息到 {self.database}.{self.be_change_table}")
            
            if self.is_version_3_or_higher:
                # 3开头版本插入所有字段
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_change_table}
                                (be_id, name, before_value, after_value, type, `default`, mutable)
                                VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            elif self.is_version_2_5:
                # 2.5开头版本只插入三列相关字段
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_change_table}
                                (be_id, name, before_value, after_value, type, `default`, mutable)
                                VALUES (%s, %s, %s, %s, '', '', false)"""
            else:
                # 默认插入所有字段
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_change_table}
                                (be_id, name, before_value, after_value, type, `default`, mutable)
                                VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for change in changes:
                    if self.is_version_3_or_higher or not self.is_version_2_5:
                        # 3开头版本或其他版本插入所有字段
                        cursor.execute(insert_sql, (
                            change['be_id'],
                            change['name'],
                            change['before_value'],
                            change['after_value'],
                            change.get('type', ''),
                            change.get('default', ''),
                            change.get('mutable', False)
                        ))
                    else:
                        # 2.5开头版本只插入必要字段
                        cursor.execute(insert_sql, (
                            change['be_id'],
                            change['name'],
                            change['before_value'],
                            change['after_value']
                        ))
                self.db_handler.commit()
                print(f"成功存储{len(changes)}条BE配置变更信息")
            except Exception as e:
                print(f"存储BE配置变更信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        # 比较并存储新增/删除的BE配置
        self.compare_be_add_drop(before_table, after_table)
    
    def compare_fe_configs(self):
        """比较FE配置变更并存储变更信息"""
        # 检查FE配置表是否存在
        before_table = f"fe_configs_before_{self.date}"
        after_table = f"fe_configs_after_{self.date}"
        
        if not self.check_table_exists(before_table):
            print(f"FE配置升级前表 {self.database}.{before_table} 不存在")
            return
        
        if not self.check_table_exists(after_table):
            print(f"FE配置升级后表 {self.database}.{after_table} 不存在")
            return
        
        # 获取变更信息
        print("比较FE配置变更...")
        sql = f"""SELECT b.`key`, b.aliasnames, b.value as before_value, a.value as after_value, b.`type`, b.ismutable, b.`comment`
                 FROM `{self.database}`.{before_table} b
                 JOIN `{self.database}`.{after_table} a ON b.`key` = a.`key`
                 WHERE b.value != a.value"""
        
        changes = self.execute_query(sql)
        if not changes:
            print("未发现FE配置变更")
        else:
            # 创建变更表
            if not self.create_fe_change_table():
                print("创建FE配置变更表失败")
                return
            
            # 插入变更数据
            print(f"存储FE配置变更信息到 {self.database}.{self.fe_change_table}")
            insert_sql = f"""INSERT INTO `{self.database}`.{self.fe_change_table}
                            (`key`, aliasnames, before_value, after_value, `type`, ismutable, `comment`)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for change in changes:
                    cursor.execute(insert_sql, (
                        change['key'],
                        change.get('aliasnames', ''),
                        change['before_value'],
                        change['after_value'],
                        change['type'],
                        change.get('ismutable', ''),
                        change['comment']
                    ))
                self.db_handler.commit()
                print(f"成功存储{len(changes)}条FE配置变更信息")
            except Exception as e:
                print(f"存储FE配置变更信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        # 比较并存储新增/删除的FE配置
        self.compare_fe_add_drop(before_table, after_table)
    
    def compare_variables(self):
        """比较variables变更并存储变更信息"""
        # 检查variables表是否存在
        before_table = f"variables_before_{self.date}"
        after_table = f"variables_after_{self.date}"
        
        if not self.check_table_exists(before_table):
            print(f"variables升级前表 {self.database}.{before_table} 不存在")
            return
        
        if not self.check_table_exists(after_table):
            print(f"variables升级后表 {self.database}.{after_table} 不存在")
            return
        
        # 获取变更信息
        print("比较variables变更...")
        sql = f"""SELECT b.variable_name, b.value as before_value, a.value as after_value
                 FROM `{self.database}`.{before_table} b
                 JOIN `{self.database}`.{after_table} a ON b.variable_name = a.variable_name
                 WHERE b.value != a.value"""
        
        changes = self.execute_query(sql)
        if not changes:
            print("未发现variables变更")
        else:
            # 创建变更表
            if not self.create_vars_change_table():
                print("创建variables变更表失败")
                return
            
            # 插入变更数据
            print(f"存储variables变更信息到 {self.database}.{self.vars_change_table}")
            insert_sql = f"""INSERT INTO `{self.database}`.{self.vars_change_table}
                            (variable_name, before_value, after_value)
                            VALUES (%s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for change in changes:
                    cursor.execute(insert_sql, (
                        change['variable_name'],
                        change['before_value'],
                        change['after_value']
                    ))
                self.db_handler.commit()
                print(f"成功存储{len(changes)}条variables变更信息")
            except Exception as e:
                print(f"存储variables变更信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        # 比较并存储新增/删除的variables
        self.compare_vars_add_drop(before_table, after_table)
    
    def compare_be_add_drop(self, before_table, after_table):
        """比较BE新增和删除的配置项，根据StarRocks版本区分处理逻辑"""
        print("比较BE新增和删除的配置项...")
        
        # 创建新增/删除表
        if not self.create_be_add_drop_table():
            print("创建BE新增/删除配置表失败")
            return
        
        # 根据版本选择不同的查询SQL
        if self.is_version_3_or_higher:
            # 3开头版本查询所有字段
            deleted_sql = f"""SELECT b.be_id, b.name, b.value, b.type, b.`default`, b.mutable
                          FROM `{self.database}`.{before_table} b
                          LEFT JOIN `{self.database}`.{after_table} a 
                          ON b.be_id = a.be_id AND b.name = a.name
                          WHERE a.be_id IS NULL"""
            added_sql = f"""SELECT a.be_id, a.name, a.value, a.type, a.`default`, a.mutable
                        FROM `{self.database}`.{after_table} a
                        LEFT JOIN `{self.database}`.{before_table} b 
                        ON a.be_id = b.be_id AND a.name = b.name
                        WHERE b.be_id IS NULL"""
        elif self.is_version_2_5:
            # 2.5开头版本只查询三列
            deleted_sql = f"""SELECT b.be_id, b.name, b.value
                          FROM `{self.database}`.{before_table} b
                          LEFT JOIN `{self.database}`.{after_table} a 
                          ON b.be_id = a.be_id AND b.name = a.name
                          WHERE a.be_id IS NULL"""
            added_sql = f"""SELECT a.be_id, a.name, a.value
                        FROM `{self.database}`.{after_table} a
                        LEFT JOIN `{self.database}`.{before_table} b 
                        ON a.be_id = b.be_id AND a.name = b.name
                        WHERE b.be_id IS NULL"""
        else:
            # 默认查询所有字段
            deleted_sql = f"""SELECT b.be_id, b.name, b.value, b.type, b.`default`, b.mutable
                          FROM `{self.database}`.{before_table} b
                          LEFT JOIN `{self.database}`.{after_table} a 
                          ON b.be_id = a.be_id AND b.name = a.name
                          WHERE a.be_id IS NULL"""
            added_sql = f"""SELECT a.be_id, a.name, a.value, a.type, a.`default`, a.mutable
                        FROM `{self.database}`.{after_table} a
                        LEFT JOIN `{self.database}`.{before_table} b 
                        ON a.be_id = b.be_id AND a.name = b.name
                        WHERE b.be_id IS NULL"""
        
        deleted_configs = self.execute_query(deleted_sql)
        added_configs = self.execute_query(added_sql)
        
        # 插入删除的配置项
        if deleted_configs:
            # 根据版本选择不同的插入SQL
            if self.is_version_3_or_higher:
                # 3开头版本插入所有字段
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_add_drop_table}
                                (be_id, name, value, type, `default`, mutable, change_type)
                                VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            elif self.is_version_2_5:
                # 2.5开头版本只插入三列，其他列设为默认值
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_add_drop_table}
                                (be_id, name, value, type, `default`, mutable, change_type)
                                VALUES (%s, %s, %s, '', '', false, %s)"""
            else:
                # 默认插入所有字段
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_add_drop_table}
                                (be_id, name, value, type, `default`, mutable, change_type)
                                VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for config in deleted_configs:
                    if self.is_version_3_or_higher or not self.is_version_2_5:
                        # 3开头版本或其他版本插入所有字段
                        cursor.execute(insert_sql, (
                            config['be_id'],
                            config['name'],
                            config['value'],
                            config.get('type', ''),
                            config.get('default', ''),
                            config.get('mutable', False),
                            '删除'
                        ))
                    else:
                        # 2.5开头版本只插入必要字段
                        cursor.execute(insert_sql, (
                            config['be_id'],
                            config['name'],
                            config['value'],
                            '删除'
                        ))
                self.db_handler.commit()
                print(f"成功存储{len(deleted_configs)}条BE删除配置信息")
            except Exception as e:
                print(f"存储BE删除配置信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        # 插入新增的配置项
        if added_configs:
            # 与删除配置项使用相同的插入SQL
            if self.is_version_3_or_higher:
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_add_drop_table}
                                (be_id, name, value, type, `default`, mutable, change_type)
                                VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            elif self.is_version_2_5:
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_add_drop_table}
                                (be_id, name, value, type, `default`, mutable, change_type)
                                VALUES (%s, %s, %s, '', '', false, %s)"""
            else:
                insert_sql = f"""INSERT INTO `{self.database}`.{self.be_add_drop_table}
                                (be_id, name, value, type, `default`, mutable, change_type)
                                VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for config in added_configs:
                    if self.is_version_3_or_higher or not self.is_version_2_5:
                        # 3开头版本或其他版本插入所有字段
                        cursor.execute(insert_sql, (
                            config['be_id'],
                            config['name'],
                            config['value'],
                            config.get('type', ''),
                            config.get('default', ''),
                            config.get('mutable', False),
                            '新增'
                        ))
                    else:
                        # 2.5开头版本只插入必要字段
                        cursor.execute(insert_sql, (
                            config['be_id'],
                            config['name'],
                            config['value'],
                            '新增'
                        ))
                self.db_handler.commit()
                print(f"成功存储{len(added_configs)}条BE新增配置信息")
            except Exception as e:
                print(f"存储BE新增配置信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        if not deleted_configs and not added_configs:
            print("未发现BE新增或删除的配置项")
    
    def compare_fe_add_drop(self, before_table, after_table):
        """比较FE新增和删除的配置项"""
        print("比较FE新增和删除的配置项...")
        
        # 创建新增/删除表
        if not self.create_fe_add_drop_table():
            print("创建FE新增/删除配置表失败")
            return
        
        # 获取删除的配置项（只存在于before表）
        deleted_sql = f"""SELECT b.`key`, b.aliasnames, b.value, b.`type`, b.ismutable, b.`comment`
                          FROM `{self.database}`.{before_table} b
                          LEFT JOIN `{self.database}`.{after_table} a 
                          ON b.`key` = a.`key`
                          WHERE a.`key` IS NULL"""
        deleted_configs = self.execute_query(deleted_sql)
        
        # 获取新增的配置项（只存在于after表）
        added_sql = f"""SELECT a.`key`, a.aliasnames, a.value, a.`type`, a.ismutable, a.`comment`
                        FROM `{self.database}`.{after_table} a
                        LEFT JOIN `{self.database}`.{before_table} b 
                        ON a.`key` = b.`key`
                        WHERE b.`key` IS NULL"""
        added_configs = self.execute_query(added_sql)
        
        # 插入删除的配置项
        if deleted_configs:
            insert_sql = f"""INSERT INTO `{self.database}`.{self.fe_add_drop_table}
                            (`key`, aliasnames, value, `type`, ismutable, `comment`, change_type)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for config in deleted_configs:
                    cursor.execute(insert_sql, (
                        config['key'],
                        config.get('aliasnames', ''),
                        config['value'],
                        config['type'],
                        config.get('ismutable', ''),
                        config['comment'],
                        '删除'
                    ))
                self.db_handler.commit()
                print(f"成功存储{len(deleted_configs)}条FE删除配置信息")
            except Exception as e:
                print(f"存储FE删除配置信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        # 插入新增的配置项
        if added_configs:
            insert_sql = f"""INSERT INTO `{self.database}`.{self.fe_add_drop_table}
                            (`key`, aliasnames, value, `type`, ismutable, `comment`, change_type)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for config in added_configs:
                    cursor.execute(insert_sql, (
                        config['key'],
                        config.get('aliasnames', ''),
                        config['value'],
                        config['type'],
                        config.get('ismutable', ''),
                        config['comment'],
                        '新增'
                    ))
                self.db_handler.commit()
                print(f"成功存储{len(added_configs)}条FE新增配置信息")
            except Exception as e:
                print(f"存储FE新增配置信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        if not deleted_configs and not added_configs:
            print("未发现FE新增或删除的配置项")
    
    def compare_vars_add_drop(self, before_table, after_table):
        """比较variables新增和删除的配置项"""
        print("比较variables新增和删除的配置项...")
        
        # 创建新增/删除表
        if not self.create_vars_add_drop_table():
            print("创建variables新增/删除表失败")
            return
        
        # 获取删除的配置项（只存在于before表）
        deleted_sql = f"""SELECT b.variable_name, b.value
                          FROM `{self.database}`.{before_table} b
                          LEFT JOIN `{self.database}`.{after_table} a 
                          ON b.variable_name = a.variable_name
                          WHERE a.variable_name IS NULL"""
        deleted_vars = self.execute_query(deleted_sql)
        
        # 获取新增的配置项（只存在于after表）
        added_sql = f"""SELECT a.variable_name, a.value
                        FROM `{self.database}`.{after_table} a
                        LEFT JOIN `{self.database}`.{before_table} b 
                        ON a.variable_name = b.variable_name
                        WHERE b.variable_name IS NULL"""
        added_vars = self.execute_query(added_sql)
        
        # 插入删除的配置项
        if deleted_vars:
            insert_sql = f"""INSERT INTO `{self.database}`.{self.vars_add_drop_table}
                            (variable_name, value, change_type)
                            VALUES (%s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for var in deleted_vars:
                    cursor.execute(insert_sql, (
                        var['variable_name'],
                        var['value'],
                        '删除'
                    ))
                self.db_handler.commit()
                print(f"成功存储{len(deleted_vars)}条variables删除配置信息")
            except Exception as e:
                print(f"存储variables删除配置信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        # 插入新增的配置项
        if added_vars:
            insert_sql = f"""INSERT INTO `{self.database}`.{self.vars_add_drop_table}
                            (variable_name, value, change_type)
                            VALUES (%s, %s, %s)"""
            
            cursor = self.db_handler.cursor()
            try:
                for var in added_vars:
                    cursor.execute(insert_sql, (
                        var['variable_name'],
                        var['value'],
                        '新增'
                    ))
                self.db_handler.commit()
                print(f"成功存储{len(added_vars)}条variables新增配置信息")
            except Exception as e:
                print(f"存储variables新增配置信息失败: {e}")
                self.db_handler.rollback()
            finally:
                cursor.close()
        
        if not deleted_vars and not added_vars:
            print("未发现variables新增或删除的配置项")
    
    def run(self):
        """执行操作"""
        try:
            self.connect()
            
            # 检查并创建数据库
            if not self.check_database_exists():
                print("创建数据库失败")
                return
            
            if self.module == "df":
                # 比较模式，只进行比较不备份
                print("开始比较升级前后配置变更...")
                
                # 比较并存储变更
                self.compare_be_configs()
                self.compare_fe_configs()
                self.compare_variables()
                
                print(f"\n配置变更比较完成！模块: {self.module}")
                print(f"日期: {self.date}")
                print(f"数据库: {self.database}")
                if hasattr(self, 'be_change_table') and self.check_table_exists(self.be_change_table):
                    print(f"BE配置变更表: {self.be_change_table}")
                if hasattr(self, 'fe_change_table') and self.check_table_exists(self.fe_change_table):
                    print(f"FE配置变更表: {self.fe_change_table}")
                if hasattr(self, 'vars_change_table') and self.check_table_exists(self.vars_change_table):
                    print(f"variables变更表: {self.vars_change_table}")
                # 输出新增/删除配置表信息
                if hasattr(self, 'be_add_drop_table') and self.check_table_exists(self.be_add_drop_table):
                    print(f"BE新增/删除配置表: {self.be_add_drop_table}")
                if hasattr(self, 'fe_add_drop_table') and self.check_table_exists(self.fe_add_drop_table):
                    print(f"FE新增/删除配置表: {self.fe_add_drop_table}")
                if hasattr(self, 'vars_add_drop_table') and self.check_table_exists(self.vars_add_drop_table):
                    print(f"variables新增/删除表: {self.vars_add_drop_table}")
            else:
                # 备份模式
                # 备份BE配置
                self.backup_be_configs()
                
                # 备份FE配置
                self.backup_fe_configs()
                
                # 备份variables
                self.backup_variables()
                
                print(f"\n配置备份完成！模块: {self.module}")
                print(f"备份日期: {self.date}")
                print(f"备份数据库: {self.database}")
                if self.check_table_exists(self.be_table_name):
                    print(f"BE配置表: {self.be_table_name}")
                if self.check_table_exists(self.fe_table_name):
                    print(f"FE配置表: {self.fe_table_name}")
                if self.check_table_exists(self.vars_table_name):
                    print(f"variables表: {self.vars_table_name}")
        finally:
            self.disconnect()

def main():
    """主函数，处理命令行参数并执行备份"""
    parser = argparse.ArgumentParser(description='StarRocks配置备份工具')
    parser.add_argument('-H', '--host', required=True, help='FE节点IP地址')
    parser.add_argument('-P', '--port', type=int, default=9030, help='FE节点端口，默认9030')
    parser.add_argument('-u', '--user', default='root', help='数据库用户名，默认root')
    parser.add_argument('-p', '--password', default='', help='数据库密码')
    parser.add_argument('-m', '--module', default='bf', choices=['bf', 'af', 'df'], help='备份模块名称，bf表示升级前备份，af表示升级后备份，df表示比较变更并存储变更后信息，默认bf')
    
    args = parser.parse_args()
    
    backup_tool = ConfigBackup(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        module=args.module
    )
    
    backup_tool.run()

if __name__ == "__main__":
    main()