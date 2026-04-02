#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
StarRocks Audit Log Parser (Ultra Safe Stream Load Edition)
"""

import sys
import argparse
import re
from datetime import datetime, timezone, timedelta

UTC_PLUS_5 = timezone(timedelta(hours=5))

# 预编译所有正则表达式，提升循环内的匹配性能
TAG_PATTERN = re.compile(r'\[([^\]]+)\]')
FIELD_PATTERN = re.compile(r'\|([^=]+?)=(.*?)(?=\|\w+=|$)', re.DOTALL)
LOG_START_PATTERN = re.compile(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.')

COLUMN_SEPARATOR = '\x1e'

# Strictly 24 columns in order
FIXED_HEADER = [
    'queryType', 'timestamp', 'clientIp', 'user', 'authorizedUser',
    'resourceGroup', 'catalog', 'db', 'state', 'errorCode',
    'queryTime', 'scanBytes', 'scanRows', 'returnRows',
    'cpuCostNs', 'memCostBytes', 'stmtId', 'queryId', 'isQuery',
    'feIp', 'stmt', 'digest', 'planCpuCosts', 'planMemCosts'
]

FIELD_MAPPING = {
    'Timestamp': 'timestamp',
    'Client': 'clientIp',
    'User': 'user',
    'AuthorizedUser': 'authorizedUser',
    'ResourceGroup': 'resourceGroup',
    'Catalog': 'catalog',
    'Db': 'db',
    'State': 'state',
    'ErrorCode': 'errorCode',
    'Time': 'queryTime',
    'ScanBytes': 'scanBytes',
    'ScanRows': 'scanRows',
    'ReturnRows': 'returnRows',
    'CpuCostNs': 'cpuCostNs',
    'MemCostBytes': 'memCostBytes',
    'StmtId': 'stmtId',
    'QueryId': 'queryId',
    'IsQuery': 'isQuery',
    'feIp': 'feIp',
    'Stmt': 'stmt',
    'Digest': 'digest',
    'PlanCpuCost': 'planCpuCosts',
    'PlanMemCost': 'planMemCosts'
}

# 优化 1：提前生成反向映射字典，将 O(N) 查找降级为 O(1)
REVERSE_FIELD_MAPPING = {v: k for k, v in FIELD_MAPPING.items()}


def extract_query_type(block: str) -> str:
    if '[slow_query]' in block:
        return 'slow_query'
    match = TAG_PATTERN.search(block)
    return match.group(1).strip() if match else 'normal'

def is_log_start(line: str) -> bool:
    # 优化 3：使用预编译的正则
    return bool(LOG_START_PATTERN.match(line.strip()))

def parse_single_log(block: str):
    return {key.strip(): value for key, value in FIELD_PATTERN.findall(block)}

def format_timestamp_to_second(ms_str: str) -> str:
    try:
        seconds = int(ms_str) // 1000
        dt_utc = datetime.fromtimestamp(seconds, tz=timezone.utc)
        return dt_utc.astimezone(UTC_PLUS_5).strftime('%Y-%m-%d %H:%M:%S')
    except (ValueError, TypeError):
        return ''

def format_scientific(value_str: str) -> str:
    try:
        formatted = f'{float(value_str):.6f}'
        return formatted.rstrip('0').rstrip('.') if '.' in formatted else formatted
    except (ValueError, TypeError):
        return value_str

def format_is_query(value_str: str) -> str:
    val = value_str.strip().lower()
    return '1' if val == 'true' else '0' if val == 'false' else ''

def replace_newlines_in_stmt(stmt_value: str) -> str:
    if not stmt_value:
        return ''
    cleaned = re.sub(r'\r\n|\r|\n', ' ', stmt_value)
    return re.sub(r'\s{2,}', ' ', cleaned).strip()

# 优化 2：提取公共处理逻辑，避免重复代码
def process_and_write_block(block_lines: list, fout) -> int:
    block = "".join(block_lines)
    parsed = parse_single_log(block)
    if not parsed:
        return 0

    row = []
    for col in FIXED_HEADER:
        if col == 'queryType':
            value = extract_query_type(block)
        elif col == 'timestamp':
            value = format_timestamp_to_second(parsed.get('Timestamp', ''))
        elif col == 'planCpuCosts':
            value = format_scientific(parsed.get('PlanCpuCost', ''))
        elif col == 'planMemCosts':
            value = format_scientific(parsed.get('PlanMemCost', ''))
        elif col == 'isQuery':
            value = format_is_query(parsed.get('IsQuery', ''))
        elif col == 'stmt':
            value = replace_newlines_in_stmt(parsed.get('Stmt', ''))
        else:
            # 使用 O(1) 的字典查找代替生成器遍历
            orig_key = REVERSE_FIELD_MAPPING.get(col)
            value = parsed.get(orig_key, '') if orig_key else ''
            
        row.append(value or '')

    fout.write(COLUMN_SEPARATOR.join(row) + '\n')
    return 1


def main():
    parser = argparse.ArgumentParser(description="Parse StarRocks audit.log → Ultra Safe Stream Load")
    parser.add_argument('input_file', help="Input audit.log file")
    parser.add_argument('output_file', help="Output file (using \\x1e as separator)")
    args = parser.parse_args()

    print("Processing StarRocks audit logs (using \\x1e ultra-safe separator)...")

    try:
        with open(args.input_file, 'r', encoding='utf-8', errors='ignore') as fin, \
             open(args.output_file, 'w', encoding='utf-8', newline='') as fout:

            fout.write(COLUMN_SEPARATOR.join(FIXED_HEADER) + '\n')

            current_block_lines = []
            valid = 0
            total_lines = 0

            for line in fin:
                total_lines += 1

                if is_log_start(line) and current_block_lines:
                    valid += process_and_write_block(current_block_lines, fout)
                    current_block_lines = [line]  # 重置并存入新日志的第一行
                else:
                    current_block_lines.append(line)

                if total_lines % 500000 == 0:
                    print(f"  Processed {total_lines:,} lines, wrote {valid:,} records...")

            # 处理文件末尾的最后一条记录
            if current_block_lines:
                valid += process_and_write_block(current_block_lines, fout)

        print(f"\nProcessing complete!")
        print(f"   Total input lines   : {total_lines:,}")
        print(f"   Records written     : {valid:,}")
        print(f"   stmt newlines converted to spaces")
        print(f"   Using \\x1e as column separator (ultra-safe)")
        print(f"   Output file         : {args.output_file}")
        print(f"   For Stream Load, make sure to add: -H \"column_separator:\\x1e\"")

    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python3 parse_sr_audit_ultra_safe.py <input.log> <output.txt>")
        sys.exit(1)
    main()