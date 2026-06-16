import pymysql
import sys

# --- 配置区域 ---
DB_CONFIG = {
    "host": "127.0.0.1",
    "port": 9030,
    "user": "root",
    "password": "",
    "database": "information_schema", 
    "charset": "utf8mb4"
}

FILE_PATH = "tablets.txt"  # 存有 tabletid 的文件
# ----------------

def get_unique_tables():
    unique_tables = set()
    not_found_tablets = []
    
    try:
        # 1. 连接数据库
        conn = pymysql.connect(**DB_CONFIG)
        cursor = conn.cursor(pymysql.cursors.DictCursor)
        
        # 2. 读取 Tablet ID 列表并去重（避免重复查询同一个 ID）
        with open(FILE_PATH, 'r') as f:
            # 过滤空行并去重输入列表
            tablet_ids = list(set(line.strip() for line in f if line.strip()))

        total = len(tablet_ids)
        print(f"检测到 {total} 个待查询的唯一 Tablet ID...")

        # 3. 循环查询
        for idx, tid in enumerate(tablet_ids, 1):
            try:
                cursor.execute(f"SHOW TABLET {tid}")
                result = cursor.fetchone()
                
                if result:
                    # 根据你提供的输出格式，提取这两列
                    db = result.get('DbName')
                    tbl = result.get('TableName')
                    
                    if db and tbl:
                        unique_tables.add(f"{db}.{tbl}")
                else:
                    not_found_tablets.append(tid)

                # 打印简易进度
                if idx % 100 == 0 or idx == total:
                    print(f"进度: {idx}/{total}...", end='\r')

            except Exception as e:
                print(f"\n查询 ID {tid} 时出错: {e}")

        # 4. 打印最终结果
        print("\n\n" + "="*40)
        print(f"去重后的库表清单 ({len(unique_tables)} 个):")
        print("="*40)
        for table in sorted(unique_tables):
            print(table)
        
        if not_found_tablets:
            print("-" * 40)
            print(f"注意: 有 {len(not_found_tablets)} 个 Tablet 未查到元数据（可能已被删除）")

    except FileNotFoundError:
        print(f"错误: 找不到文件 {FILE_PATH}")
    except Exception as e:
        print(f"数据库连接失败: {e}")
    finally:
        if 'conn' in locals():
            conn.close()

if __name__ == "__main__":
    get_unique_tables()