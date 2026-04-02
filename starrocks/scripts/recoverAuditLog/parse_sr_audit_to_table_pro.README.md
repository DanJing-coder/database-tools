# parse_sr_audit_to_table_pro.py 使用说明

本文件是 `recoverAuditLog` 模块中优化版的 StarRocks 审计日志解析脚本。相比基础脚本（`parse_sr_audit_to_table.py`），`parse_sr_audit_to_table_pro.py` 具备：

- 预编译正则，提高大文件解析速度
- 代码模块化（`process_and_write_block`），便于维护和扩展
- 使用 `
` 的统一字段顺序输出（24列固定）
- 持久化异常处理与友好日志提示

## 主要功能

1. 识别审计日志每条记录起始行（时间戳格式 `YYYY-MM-DD HH:MM:SS.xxx`）
2. 按字段名提取 `|Key=Value` 结构数据
3. 生成固定表头并使用超安全分隔符 `\x1e` 输出
4. 将 `stmt` 中换行转换为空格，便于 Stream Load 导入
5. cleanup并退出状态保护

## 固定输出列
`queryType`, `timestamp`, `clientIp`, `user`, `authorizedUser`, `resourceGroup`, `catalog`, `db`, `state`, `errorCode`, `queryTime`, `scanBytes`, `scanRows`, `returnRows`, `cpuCostNs`, `memCostBytes`, `stmtId`, `queryId`, `isQuery`, `feIp`, `stmt`, `digest`, `planCpuCosts`, `planMemCosts`

## 使用方法

```bash
cd .../starrocks/scripts/recoverAuditLog
python3 parse_sr_audit_to_table_pro.py /path/to/fe.audit.log /path/to/output.txt
```

其中：
- `input.log` 可以是 `fe.audit.log` 或 `audit.log` 等 FE 审计日志
- `output.txt` 为解析后文件，可直接作为 Stream Load 数据源

## Stream Load 示例

```sql
LOAD LABEL label_name (
  `queryType` varchar(20),
  ...
) WITH (
  "column_separator"="\x1e",
  "format"="csv"
);
```

## 常见问题排查

- 找不到日志条目：检查输入文件是否为服务器上完整的审计文件，是否包含时间戳首行
- 导入失败：确认 `column_separator` 为`\x1e`，并且表字段顺序与脚本输出一致
- 语句空白：可能因 `QueryId` 缺失或日志字段名变更，需调整 `FIELD_MAPPING`
