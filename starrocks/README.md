# 该工具主要有以下功能
- 检测每个表的分桶个数
- 检测分桶是否存在数据倾斜
- 检测单副本分区或者表
- 检测单分桶分区或者表
- 检测数据为0的分区

# 使用方法

```shell

$ python healthy_report.py --help
usage: healthy_report.py [-h] --host HOST --port PORT --user USER --password PASSWORD [--mode {shared_nothing,shared_data}] [--replica REPLICA] [--bucket BUCKET] [--partition_size PARTITION_SIZE]
                         [--module {all,buckets,tablets,partitions,replicas}] [--debug] [--format {table,json,yaml}] [--output-dir OUTPUT_DIR]

StarRocks Health Report Tool

optional arguments:
  -h, --help            show this help message and exit
  --host HOST           FE host address
  --port PORT           FE query port
  --user USER           Database user
  --password PASSWORD   Database password
  --mode {shared_nothing,shared_data}
                        Cluster mode
  --replica REPLICA     replica number
  --bucket BUCKET       bucket number
  --partition_size PARTITION_SIZE
                        partition size
  --module {all,buckets,tablets,partitions,replicas}
                        Module to run
  --debug               Enable debug mode
  --format {table,json,yaml}
                        Output format
  --output-dir OUTPUT_DIR
                        Output directory for reports

# 结果说明
会输出多个表格

![image](https://github.com/user-attachments/assets/25c0ad93-227b-4d38-b376-f624de9df33e)

*********************** The Tables of all databases  **************************
表示集群中所有表的数据量以及分桶的个数、分桶平均数据量和分桶数据量的标准差

datasize of table(/MB)：表的存储大小，三副本后的数据
replica_counts：表的副本个数（三副本）
avg of tablet datasize(/MB)：单个桶的数据大小（单副本）
standard deviation of tablet datasize：单副本单个桶的数据量标准差，这个值越大表示桶的数据量越偏离桶的数据量平均值，也就存在数据倾斜（去除空分区）

*********************** The Tables of 1 Replicas **************************

![image](https://github.com/user-attachments/assets/00bb63cd-8b7c-4669-9734-541e7cc32165)


表示集群中单个副本的分区或者表
test_map3(schema is 1 replica)：表示test_tb3这个表的建表语句中是1副本
the number of partitions：单副本的分区个数
partition of 1 replica：单副本表分区，如果不是分区表，这块显示的即是表名


*********************** The Tables of 1 Buckets **************************

![image](https://github.com/user-attachments/assets/17c67ff9-7abd-49b5-91c5-aaac1dbecf3e)


表示集群中单个桶的分区或者表
test_map3(schema is 1 bucket)：表示test_tb3这个表的建表语句中是1个桶
the number of partitions：单个桶的分区个数
partition of 1 bucket：单个桶的分区，如果不是分区表，这块显示的即是表名


*********************** The Tables of Null Partitions **************************

![image](https://github.com/user-attachments/assets/3cd2f0ef-e9ed-4ced-a99e-00e742a18c29)

表示集群中存在的空分区
The number of null partitions：数据为0的分区个数
null partitions：数据为0的分区名字，通过逗号拼接，如果不是分区表，这块显示的即是表名
