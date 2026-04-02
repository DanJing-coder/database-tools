# sr_tablets_Info_analyser 目录说明

本目录主要用于 StarRocks 表/Tablet 健康分析与诊断建议产出，包含数据采集与规则判断两个阶段。

## 脚本列表

- `check_replica.py`：统计数据库/表/分区的大小、分区数、副本数、Tablet倾斜度（含 JSON输出）
- `sr_advise_analyser.py`：基于 `check_replica.py` 输出结果进行问题分类与优化建议

---

## 1. check_replica.py

### 功能
- 通过 `SHOW DATABASES`,`SHOW TABLES`, `SHOW PARTITIONS`, `SHOW TABLET` 采集元数据信息
- 计算指标：总体大小、分区数、ReplicaCounts、AvgTablet、StdDev、EmptyParts
- 支持按 `--databases` 过滤
- 支持输出 `--format table|json`

### 示例
```bash
python3 check_replica.py --host fe_host --port 9030 --user admin --password pwd --format json > report.json
python3 check_replica.py --host fe_host --port 9030 --user admin --password pwd --databases db1,db2 --format table
```

---

## 2. sr_advise_analyser.py

### 功能
- 读取 `check_replica.py` 生成的 JSON 结果
- 根据规则输出分类诊断：
  - CRITICAL_SKEW（严重倾斜）
  - METADATA_PRESSURE（元数据压力）
  - HUGE_TABLET（单分片过大）
  - EMPTY_PARTITION（空分区过多）
- 建议优先处理 `METADATA_PRESSURE` 与 `CRITICAL_SKEW`

### 示例
```bash
python3 sr_advise_analyser.py report.json
```

---

## 运营建议
- 定期执行 `check_replica.py`（如周滚动）并存档 JSON 数据
- 结合 `sr_advise_analyser.py` 输出对热点表进行分桶/分区策略优化
- 对 `HUGE_TABLET` 表可考虑增加 `BUCKETS` 或重分区以降低单 Tablet 体积
- 对 `EMPTY_PARTITION` 进行分区策略审查（避免过细分区）
