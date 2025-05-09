# StarRocks Health Report Tool

A comprehensive tool for analyzing and reporting the health status of StarRocks database clusters. This tool provides detailed insights into table replicas, buckets, partitions, and overall database health.

## Features

- **Replica Health Check**: Analyzes replication status and consistency across tables
- **Bucket Analysis**: Examines bucket distribution and health
- **Partition Management**: Monitors partition sizes and distribution
- **Data Size Analysis**: Tracks data size across tables and partitions
- **Multiple Output Formats**: Supports table, JSON, and YAML output formats
- **Detailed Reporting**: Generates comprehensive health reports with statistics

## Prerequisites

- Python 3.x
- Required Python packages:
  - pymysql
  - prettytable
  - numpy
  - pyyaml

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd <repository-directory>
```

2. Install required packages:
```bash
pip install pymysql prettytable numpy pyyaml
```

## Usage

### Basic Usage

```bash
python healthy_report.py -h <host> -P <port> -u <user> -p <password> [options]
```

### Command Line Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `-h` | StarRocks host | localhost |
| `-P` | StarRocks port | 9030 |
| `-u` | Username | - |
| `-p` | Password | - |
| `-m` | Mode (shared_nothing/shared_data) | shared_nothing |
| `-r` | Replica number to check | - |
| `-b` | Bucket number to check | - |
| `-f` | Output format (table/json/yaml) | table |
| `-o` | Output directory | ./reports |
| `-d` | Enable debug mode | False |

### Output Formats

The tool supports three output formats:

1. **Table Format** (default)
   - Human-readable tabular output
   - Shows detailed statistics and health metrics

2. **JSON Format**
   - Structured JSON output
   - Suitable for programmatic processing

3. **YAML Format**
   - YAML-formatted output
   - Easy to read and parse

### Example Commands

1. Basic health check:
```bash
python healthy_report.py -h localhost -P 9030 -u root -p password
```

2. Check specific replica number:
```bash
python healthy_report.py -h localhost -P 9030 -u root -p password -r 3
```

3. Generate JSON report:
```bash
python healthy_report.py -h localhost -P 9030 -u root -p password -f json
```

## Report Contents

The health report includes:

- **Table Information**
  - Database and table names
  - Data size
  - Replica counts
  - Mean data size
  - Standard deviation
  - Partition information

- **Replica Health**
  - Replica distribution
  - Consistency checks
  - Replication status

- **Bucket Analysis**
  - Bucket distribution
  - Size distribution
  - Health metrics

- **Partition Information**
  - Partition sizes
  - Distribution analysis
  - Health status

## Output Files

Reports are saved in the specified output directory (default: `./reports`) with the following structure:

- `health_report.<format>`: Overall health report
- `replica_info.<format>`: Replica-specific information
- `bucket_info.<format>`: Bucket analysis
- `partitions_info.<format>`: Partition details

## Error Handling

The tool includes comprehensive error handling for:
- Connection issues
- Query failures
- Data parsing errors
- Invalid configurations

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.