import pymysql
from datetime import datetime
import sys

# 脚本功能是定期查询 StarRocks 中指定 DBID 的 Tablet 统计信息，并将结果插入到一个监控表中。DBID 列表是硬编码在脚本中的，查询结果包括不健康的 Tablet 数量、不一致的 Tablet 数量、克隆中的 Tablet 数量和错误状态的 Tablet 数量。脚本会记录每次查询的时间戳，并将所有数据插入到指定的表中，以便后续分析和监控使用。

# ================= 配置区域 =================
SR_CONFIG = {
    'host': 'dwh-dbr18-lp2',      
    'port': 9030,             
    'user': 'user_name',
    'password': '', 
    'db': '',
    'charset': 'utf8mb4'
}

# 目标表名
TARGET_TABLE = 'monitor_db_tablet_stat'

# 硬编码需要执行的 DBID 列表
DB_IDS = [
    1263761731, 712124060, 936863612
]

# ============================================

def collect_and_insert():
    conn = None
    try:
        print("Connecting to StarRocks...")
        conn = pymysql.connect(**SR_CONFIG)
        cursor = conn.cursor()
        
        rows_to_insert = []
        current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        # current_time = datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
        # current_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
        
        print(f"Start collecting metrics at {current_time}...")
        
        for db_id in DB_IDS:
            try:
                # 执行命令
                sql_show = f"SHOW PROC '/statistic/{db_id}'"
                cursor.execute(sql_show)
                result = cursor.fetchone()
                
                if result and len(result) >= 4:
                    # 使用负数索引动态获取最后四列
                    # -4: UnhealthyTablets
                    # -3: InconsistentTablets
                    # -2: CloningTablets
                    # -1: ErrorStateTablets
                    row_data = (
                        current_time,              # update_time
                        str(db_id),                # db_id
                        str(result[-4]),           # unhealthy_tablets
                        str(result[-3]),           # inconsistent_tablets
                        str(result[-2]),           # cloningTablets
                        str(result[-1])            # errorStateTablets
                    )
                    rows_to_insert.append(row_data)
                elif result:
                    print(f"Warning: DBID {db_id} returned too few columns ({len(result)})")
                else:
                    print(f"Warning: No result for DBID {db_id}")
                    
            except Exception as e:
                print(f"Error querying DBID {db_id}: {e}")
                
        if rows_to_insert:
            print(f"Collected {len(rows_to_insert)} rows. Inserting into {TARGET_TABLE}...")
            
            # 使用与表结构一致的插入语句
            sql_insert = f"""
                INSERT INTO {TARGET_TABLE} 
                (update_time, db_id, unhealthy_tablets, inconsistent_tablets, cloningTablets, errorStateTablets) 
                VALUES (%s, %s, %s, %s, %s, %s)
            """
            
            cursor.executemany(sql_insert, rows_to_insert)
            conn.commit()
            print("Insert successfully!")
        else:
            print("No data collected to insert.")
            
    except pymysql.MySQLError as err:
        print(f"Database Error: {err}")
    finally:
        if conn:
            conn.close()
            print("Connection closed.")

if __name__ == "__main__":
    collect_and_insert()