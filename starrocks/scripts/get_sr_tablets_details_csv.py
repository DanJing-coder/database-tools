import pymysql
import os
import csv
import argparse
import sys
import time

# 脚本功能是批量获取传入的tablet的详细信息，可以获取副本的信息，并且支持输出到CSV文件中。输入的tablet ID可以通过文件传入，文件中可以是逗号分隔或者换行分隔的ID列表。
# ================= 配置区域 =================
DB_CONFIG = {
    'host': '',      # FE IP
    'port': 9030,             # Query Port
    'user': 'user_name',           # 用户名
    'password': '',           # 密码
    'database': 'information_schema',
    'charset': 'utf8mb4',
    'cursorclass': pymysql.cursors.DictCursor
}
# ===========================================

def get_args():
    parser = argparse.ArgumentParser(description='StarRocks Tablet 信息导出工具 (增强版)')
    parser.add_argument('-i', '--input', required=True, help='包含 Tablet ID 的文件路径')
    parser.add_argument('-o', '--output', default='sr_export', help='输出文件名前缀 (默认: sr_export)')
    parser.add_argument('-d', '--dir', default='./result', help='输出目录 (默认: ./result)')
    parser.add_argument('-m', '--mode', choices=['all', 'basic', 'replicas'], default='all', 
                        help='导出模式: all(全部), basic(仅SHOW TABLET), replicas(仅SHOW PROC详情)')
    return parser.parse_args()

def parse_input_file(filepath):
    if not os.path.exists(filepath):
        print(f"[Error] 输入文件 {filepath} 不存在")
        sys.exit(1)
    
    ids = []
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
        items = content.replace('\n', ',').split(',')
        for item in items:
            clean = item.strip()
            if clean.isdigit():
                ids.append(clean)
    return list(set(ids))

def main():
    args = get_args()
    
    # 1. 准备目录
    if not os.path.exists(args.dir):
        try:
            os.makedirs(args.dir)
            print(f"[*] 已创建输出目录: {args.dir}")
        except Exception as e:
            print(f"[Error] 无法创建目录 {args.dir}: {e}")
            sys.exit(1)

    # 2. 解析 ID
    tablet_ids = parse_input_file(args.input)
    if not tablet_ids:
        print("[Warn] 未找到有效的 Tablet ID")
        return

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    
    # 定义文件路径
    path_basic = os.path.join(args.dir, f"{args.output}_basic_{timestamp}.csv")
    path_replicas = os.path.join(args.dir, f"{args.output}_replicas_{timestamp}.csv")

    print(f"[*] 模式: {args.mode}")
    print(f"[*] 待处理 Tablet: {len(tablet_ids)}")

    # 3. 数据库操作
    conn = None
    f_basic = None
    f_rep = None
    
    try:
        conn = pymysql.connect(**DB_CONFIG)
        cursor = conn.cursor()

        # 根据模式初始化 CSV Writer
        writer_basic = None
        writer_rep = None

        # 打开文件句柄 (只打开需要的)
        if args.mode in ['all', 'basic']:
            f_basic = open(path_basic, 'w', newline='', encoding='utf-8-sig')
            print(f"[*] Basic 结果将写入: {path_basic}")
        
        if args.mode in ['all', 'replicas']:
            f_rep = open(path_replicas, 'w', newline='', encoding='utf-8-sig')
            print(f"[*] Replicas 结果将写入: {path_replicas}")

        success_count = 0

        for idx, tid in enumerate(tablet_ids):
            try:
                # --- Step 1: SHOW TABLET ---
                cursor.execute(f"SHOW TABLET {tid}")
                basic_rows = cursor.fetchall()

                if not basic_rows:
                    print(f"[{idx+1}] ID {tid}: 未找到 Tablet 信息")
                    continue

                # 如果需要 basic 信息，写入文件
                if args.mode in ['all', 'basic']:
                    if writer_basic is None:
                        headers = basic_rows[0].keys()
                        writer_basic = csv.DictWriter(f_basic, fieldnames=headers)
                        writer_basic.writeheader()
                    writer_basic.writerows(basic_rows)

                # --- Step 2: SHOW PROC (DetailCmd) ---
                # 如果模式是 basic，跳过这里以节省时间
                if args.mode in ['all', 'replicas']:
                    for row in basic_rows:
                        # 兼容字段名
                        proc_sql = row.get('DetailCmd') or row.get('DetailCmds')
                        
                        if proc_sql:
                            cursor.execute(proc_sql)
                            replica_rows = cursor.fetchall()
                            
                            if replica_rows:
                                # 注入关联 ID
                                for r_row in replica_rows:
                                    r_row['Ref_TabletId'] = tid
                                
                                if writer_rep is None:
                                    # 调整列顺序，让 Ref_TabletId 排第一
                                    headers = list(replica_rows[0].keys())
                                    if 'Ref_TabletId' in headers:
                                        headers.remove('Ref_TabletId')
                                        headers.insert(0, 'Ref_TabletId')
                                    
                                    writer_rep = csv.DictWriter(f_rep, fieldnames=headers)
                                    writer_rep.writeheader()
                                
                                writer_rep.writerows(replica_rows)
                
                # 打印进度
                print(f"[{idx+1}/{len(tablet_ids)}] ID {tid}: 处理成功")
                success_count += 1

            except Exception as e:
                print(f"[{idx+1}/{len(tablet_ids)}] ID {tid}: [Error] {e}")

    except Exception as e:
        print(f"[Fatal] 数据库连接失败: {e}")
    finally:
        # 安全关闭
        if f_basic: f_basic.close()
        if f_rep: f_rep.close()
        if conn: conn.close()
        print(f"[*] 任务完成，成功: {success_count}/{len(tablet_ids)}")

if __name__ == "__main__":
    main()