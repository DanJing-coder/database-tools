# StarRocks Doctor

StarRocks Doctor is a command-line tool for diagnosing and collecting StarRocks cluster information. It helps users collect cluster status, configuration information, performance metrics, and other data for problem diagnosis and performance analysis.

## Features

- Multiple diagnostic modules:
  - Table structure information collection
  - Materialized view information collection
  - Tablet metadata collection
  - Replica status check and repair
  - Session variables collection
  - BE/FE configuration collection
  - Cluster state collection
  - Performance diagnostics
  - Query analysis
  - BE node stack trace

- Multiple output formats:
  - JSON (default)
  - CSV
  - YAML
  - TXT

## Installation Requirements

- Python 3.6+
- mysql-connector-python
- PyYAML (if using YAML output format)

```bash
pip install mysql-connector-python pyyaml
```

## Usage

### Basic Usage

```bash
python starrocks-doctor.py --host <FE_HOST> --port <FE_PORT> --user <USERNAME> --password <PASSWORD> --module <MODULE_NAME> [other options]
```

### Required Parameters

- `--host`: FE node hostname or IP address
- `--port`: FE node port (default: 9030)
- `--user`: Username
- `--password`: Password
- `--module`: Diagnostic module to run

### Optional Parameters

- `--output`: Output directory (default: ./starrocks_diagnostic)
- `--format`: Output format (json/csv/yaml/txt, default: json)
- `--name`: Table name, materialized view name, or Tablet ID
- `--sql_file`: SQL file path for query analysis module
- `--be_ip`: BE node IP address (for stack trace module)

### Diagnostic Modules

1. `schema`: Collect table structure information
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module schema
   ```

2. `mv`: Collect materialized view information
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module mv
   ```

3. `tablet`: Collect Tablet metadata
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module tablet
   ```

4. `check_replica`: Check and repair replica status
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module check_replica --name <tablet_id>
   ```

5. `session_vars`: Collect modified session variables
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module session_vars
   ```

6. `be_config`: Collect modified BE configurations
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module be_config
   ```

7. `fe_config`: Collect FE configurations
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module fe_config
   ```

8. `all_configs`: Collect all configuration information
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module all_configs
   ```

9. `cluster_state`: Collect cluster state
   ```bash
   python starrocks-doctor.py --host localhost --user root --password xxx --module cluster_state
   ```

10. `performance_diagnostics`: Collect performance diagnostic information
    ```bash
    python starrocks-doctor.py --host localhost --user root --password xxx --module performance_diagnostics
    ```

11. `query_dump`: Analyze SQL file
    ```bash
    python starrocks-doctor.py --host localhost --user root --password xxx --module query_dump --sql_file <sql_file_path>
    ```

12. `be_stack`: Get BE node stack trace
    ```bash
    python starrocks-doctor.py --host localhost --user root --password xxx --module be_stack --be_ip <be_ip>
    ```

## Output Description

The tool generates diagnostic files in the specified output directory (default: `./starrocks_diagnostic`). The file naming format is:
```
<module_name>_<timestamp>.<format>
```

Examples:
- `table_info_20240315_123456.json`
- `cluster_state_20240315_123456.csv`
- `performance_diagnostics_20240315_123456.yaml`

## Notes

1. Ensure the user has sufficient permissions to access required information
2. For large clusters, some modules (such as performance diagnostics) may take longer to complete
3. Regular collection of diagnostic information is recommended for problem tracking and performance analysis
4. Sensitive information (such as passwords) should be provided through environment variables or configuration files

## Error Handling

The tool provides detailed error information when encountering issues, including:
- Connection errors
- Permission errors
- Query execution errors
- Data collection errors