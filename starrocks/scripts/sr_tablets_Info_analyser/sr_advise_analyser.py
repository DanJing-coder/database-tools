# -*- coding: utf-8 -*-

import json
import sys

# 脚本功能是分析StarRocks库表的健康度，基于之前生成的JSON报告，按照预设的规则对表进行分类诊断，并输出针对每类问题的建议。主要关注数据倾斜、元数据压力、单分片过大和空分区浪费四个方面。

def analyse_report(json_file):
    try:
        with open(json_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        print(f"读取文件失败: {e}")
        return

    # 定义分类容器
    categories = {
        "CRITICAL_SKEW": [],        # 严重数据倾斜
        "METADATA_PRESSURE": [],     # 元数据压力（分片过小且数量多）
        "HUGE_TABLET": [],          # 单分片过大（影响迁移效率）
        "EMPTY_PARTITION": []       # 资源浪费（空分区过多）
    }

    for item in data:
        # 提取基础数据
        db_table = f"{item['Database']}.{item['Table']}"
        avg_size = item.get('AvgTablet(MB)', 0)
        std_dev = item.get('StdDev', 0)
        replica_count = item.get('ReplicaCounts', 0)
        total_parts = item.get('Partitions', 0)
        empty_parts = item.get('EmptyParts', 0)
        
        # 1. 计算变异系数 (CV)，衡量倾斜程度
        cv = std_dev / avg_size if avg_size > 0 else 0
        
        # 2. 判定逻辑
        
        # 判定 A: 严重倾斜 (CV > 0.5)
        if cv > 0.5:
            categories["CRITICAL_SKEW"].append({
                "table": db_table, 
                "val": f"CV={round(cv, 2)}",
                "reason": f"Tablet大小极不均匀，建议检查 DISTRIBUTED BY HASH 选列"
            })
            
        # 判定 B: 元数据压力 (平均分片 < 2048MB 且 副本数 > 10000)
        # 根据用户需求，阈值从 100MB 调优为 2048MB (2GB)
        if avg_size < 2048 and replica_count > 10000:
            categories["METADATA_PRESSURE"].append({
                "table": db_table, 
                "val": f"Avg={round(avg_size, 2)}MB, Repls={replica_count}",
                "reason": f"分片太碎且副本数巨大，会阻塞集群Balance并消耗FE内存"
            })
            
        # 判定 C: 单体过大 (平均分片 > 10GB)
        if avg_size > 10240:
            categories["HUGE_TABLET"].append({
                "table": db_table, 
                "val": f"Avg={round(avg_size/1024, 2)}GB",
                "reason": f"单个Tablet过大，建议增加 BUCKETS 数提高并行度及恢复速度"
            })
            
        # 判定 D: 空分区浪费 (空分区占比 > 50% 且分区总数 > 5)
        if total_parts > 5 and (empty_parts / total_parts) > 0.5:
            categories["EMPTY_PARTITION"].append({
                "table": db_table, 
                "val": f"Empty={empty_parts}/{total_parts}",
                "reason": f"存在大量空分区，建议检查分区键选择或数据导入覆盖情况"
            })

    # 打印诊断报告
    print("\n" + "="*80)
    print("StarRocks 库表健康度治理诊断报告 (阈值: 2GB)".center(80))
    print("="*80)

    order = ["CRITICAL_SKEW", "METADATA_PRESSURE", "HUGE_TABLET", "EMPTY_PARTITION"]
    titles = {
        "CRITICAL_SKEW": "🔥 严重数据倾斜 (导致BE负载不均/Apply报错)",
        "METADATA_PRESSURE": "📦 元数据碎片化 (导致FE内存压力/Balance缓慢)",
        "HUGE_TABLET": "🐘 单分片过大 (影响扩容迁移效率)",
        "EMPTY_PARTITION": "🈳 空分区浪费 (元数据无谓消耗)"
    }

    for cat in order:
        tables = categories[cat]
        if not tables:
            continue
            
        print(f"\n{titles[cat]}")
        print("-" * 80)
        print(f"{'Table_Name':<45} | {'Metric':<20} | {'Suggestion'}")
        for t in tables:
            print(f"{t['table']:<45} | {t['val']:<20} | {t['reason']}")
    
    print("\n" + "="*80)
    print("建议：优先处理 METADATA_PRESSURE 和 CRITICAL_SKEW 类别的表。".center(80))
    print("="*80 + "\n")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("使用说明: ")
        print("  1. 先运行获取数据: python healthy_report.py --format json > report.json")
        print("  2. 再运行分析脚本: python sr_advise_analyser.py report.json")
    else:
        analyse_report(sys.argv[1])