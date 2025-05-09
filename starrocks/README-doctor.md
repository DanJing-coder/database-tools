# StarRocks Doctor

StarRocks Doctor 是一个用于诊断和收集 StarRocks 集群信息的命令行工具。它可以帮助用户收集集群状态、配置信息、性能指标等数据，以便进行问题诊断和性能分析。

## 功能特点

- 支持多种诊断模块：
  - 表结构信息收集
  - 物化视图信息收集
  - Tablet 元数据收集
  - 副本状态检查和修复
  - 会话变量收集
  - BE/FE 配置收集
  - 集群状态收集
  - 性能诊断
  - 查询分析
  - BE 节点堆栈跟踪

- 支持多种输出格式：
  - JSON（默认）
  - CSV
  - YAML
  - TXT

## 安装要求

- Python 3.6+
- mysql-connector-python
- PyYAML (如果使用 YAML 输出格式)

```bash
pip install mysql-connector-python pyyaml
```

## 使用方法

### 基本用法

```bash
python starrocks-doctor.py --host <FE_HOST> --port <FE_PORT> --user <USERNAME> --password <PASSWORD> --module <MODULE_NAME> [其他选项]
```

### 必需参数

- `--host`: FE 节点主机名或 IP 地址
- `--port`: FE 节点端口（默认：9030）
- `--user`: 用户名
- `--password`: 密码
- `--module`: 要运行的诊断模块

### 可选参数

- `--output`: 输出目录（默认：./starrocks_diagnostic）
- `--format`: 输出格式（json/csv/yaml/txt，默认：json）
- `--name`: 表名、物化视图名或 Tablet ID
- `--sql_file`: 查询分析模块的 SQL 文件路径
- `--be_ip`: BE 节点 IP 地址（用于堆栈跟踪模块）

### 诊断模块说明

1. `schema`: 收集表结构信息
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module schema
   ```

2. `mv`: 收集物化视图信息
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module mv
   ```

3. `tablet`: 收集 Tablet 元数据
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module tablet
   ```

4. `check_replica`: 检查并修复副本状态
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module check_replica --name <tablet_id>
   ```

5. `session_vars`: 收集修改过的会话变量
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module session_vars
   ```

6. `be_config`: 收集修改过的 BE 配置
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module be_config
   ```

7. `fe_config`: 收集 FE 配置
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module fe_config
   ```

8. `all_configs`: 收集所有配置信息
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module all_configs
   ```

9. `cluster_state`: 收集集群状态
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module cluster_state
   ```

10. `performance_diagnostics`: 收集性能诊断信息
    ```bash
    python starrocks-doctor.py --host localhost --user root --password xxx --module performance_diagnostics
    ```

11. `query_dump`: 分析 SQL 文件
    ```bash
    python starrocks-doctor.py --host localhost --user root --password xxx --module query_dump --sql_file <sql_file_path>
    ```

12. `be_stack`: 获取 BE 节点堆栈跟踪
    ```bash
    python starrocks-doctor.py --host localhost --user root --password xxx --module be_stack --be_ip <be_ip>
    ```

## 输出说明

工具会在指定的输出目录（默认为 `./starrocks_diagnostic`）中生成诊断文件，文件名格式为：
```
<module_name>_<timestamp>.<format>
```

例如：
- `table_info_20240315_123456.json`
- `cluster_state_20240315_123456.csv`
- `performance_diagnostics_20240315_123456.yaml`

## 注意事项

1. 确保用户具有足够的权限访问所需的信息
2. 对于大型集群，某些模块（如性能诊断）可能需要较长时间
3. 建议定期收集诊断信息，以便进行问题追踪和性能分析
4. 敏感信息（如密码）建议通过环境变量或配置文件提供

## 错误处理

工具会在遇到错误时提供详细的错误信息，包括：
- 连接错误
- 权限错误
- 查询执行错误
- 数据收集错误

