# be_crash_check 目录说明

本目录主要用于 StarRocks BE 崩溃（crash）问题定位与 SQL 溯源，推荐顺序：

1. `filter_be_crash.sh` - 收集 BE 宕机堆栈日志，并进行去噪过滤
2. `batch_get_crash_sql.sh` - 从步骤1产出的 crash 日志中批量提取 QueryID，并反查 SQL
3. `get_query_sql.sh` - 通过 QueryID 查询对应执行 SQL 详情（也可单独使用）

---

## 1. filter_be_crash.sh

功能：
- 通过 SSH 遍历 BE 节点（IP 列表由 hosts 文件指定）
- 自动定位 `be.out` 路径（进程定位 + 常见安装路径）
- 利用 awk 进行堆栈块提取与噪音过滤（DateTime parsing、网络警告、JEMALLOC 等）
- 生成输出目录：`be_crash_logs_<YYYYMMDD>`
- 输出每个节点 `crash_log_<IP>_<YYYYMMDD>.log` + `summary_<YYYYMMDD>.txt`

示例：
```bash
cd starrocks/scripts/be_crash_check
./filter_be_crash.sh -d "Jan 13" /path/to/be_hosts.txt
```

关键结果：`be_crash_logs_20260113/` 中的 crash 日志文件

---

## 2. batch_get_crash_sql.sh

功能：
- 扫描 `filter_be_crash.sh` 输出目录中的 `crash_log_*.log`，提取 `query_id:...`
- 去重 QueryID
- 使用 `get_query_sql.sh` 逐个反查 SQL（基于目录名自动识别日期 `YYYYMMDD`，并传递 `-d YYYY-MM-DD`）
- 生成 `final_crash_sql_summary_<timestamp>.txt`

示例：
```bash
cd starrocks/scripts/be_crash_check
./batch_get_crash_sql.sh be_crash_logs_20260113
```

注意：`QUERY_SQL_SCRIPT` 变量在脚本中指向 `./get_query_sql.sh`，可根据实际路径调整。

---

## 3. get_query_sql.sh

功能：
- 给定 `queryId` 和可选日期，从 FE 日志/审计表定位 SQL 语句
- 流程：
  - 阶段1：在 FE `fe.log` 内查 `transfer QueryId:*` 进行内外部ID映射
  - 阶段2：查询 `starrocks_audit_db__.starrocks_audit_tbl__`
  - 阶段3：并发扫描 FE 节点 `fe.audit.log` 文件查 SQL
- 支持忽略特定用户（`IGNORE_USER` 变量）

示例：
```bash
cd starrocks/scripts/be_crash_check
./get_query_sql.sh -q 00000000-0000-0000-0000-000000000000 -d 2026-01-13
```

---

## 推荐故障定位流程

1. 先执行 `filter_be_crash.sh`，得到纯净 BE Crash 堆栈与 `be_crash_logs_<date>` 目录
2. 执行 `batch_get_crash_sql.sh be_crash_logs_<date>`，快速批量获取涉及的 SQL
3. 对重点 QueryID 再单独运行 `get_query_sql.sh -q <queryId> -d <date>`，查看完整 SQL 与来源

> 如果某个 QueryID 在审计表里查不到，可检查是否跨天、审计开关、`IGNORE_USER` 过滤条件、FE 节点可达性。

---

## 依赖与环境

- `ssh` 访问所有 FE/BE 节点
- FE 及 BE 日志路径规范
- MySQL 可访问：`starrocks_audit_db__.starrocks_audit_tbl__`
- `mysql` CLI 在执行机器可用

---

## 维护建议

- 及时检查 FE/BE 日志路径和版本，一些路径或日志格式在升级后需要调整
- `get_query_sql.sh` 中 `SR_HOST SR_PORT SR_USER` 需据实际 FE 环境配置
- 如需打印更多调试信息可临时加入 `set -x` 并审阅脚本执行输出
