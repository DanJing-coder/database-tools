# 该工具主要有以下功能
- 检测每个表的分桶个数
- 检测分桶是否存在数据倾斜
- 检测单副本分区或者表
- 检测单分桶分区或者表
- 检测数据为0的分区

# 使用方法
配置文件config.ini

```text
[common]
#fe ip，建议使用leader fe
fe_host = 
#查询的端口，默认9030
fe_query_port = 9030
#建议使用root用户或者具有cluster_admin权限的用户
user = root
#对应用户的密码
password = 
#部署架构，存算一体(shared_nothing)或者存算分离(shared_data)
run_mode = shared_data
```

```shell
tar -xf tools-20240717.tar.gz && cd tools-20240717
#补充集群连接信息，databases不写，会扫描所有库和表
vi config.ini
#授予可执行权限
chmod +x healthy_report
#默认检测所有表的倾斜情况和单副本表
./healthy_report --config ./config.ini
#可查看help信息
./healthy_report --help
#查看单副本的表
./healthy_report --config ./config.ini --module replicas --replica 1
#查看单个桶的分区或者表
./healthy_report --config ./config.ini --module buckets --bucket 1
```

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
