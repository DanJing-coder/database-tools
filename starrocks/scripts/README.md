# starrocks 基础环境检查脚本
需要打通执行该脚本的节点到其他节点的ssh免密

```shell
sh ./env_check.sh -h$fe_ip -uroot -P9030 -pxxx
```

# 检查be节点的brpc是否卡住，并打印stack
修改对应的参数

```shell
nohup sh ./check_brpc.sh 2>&1 >> brpc.log &
```

# 检查fe是否死锁并自动重启

```shell
nohup sh ./check_deadlock.sh 2>&1 >> deadlock.log &
```

# 按照表粒度备份和恢复
执行前需要修改对应的集群连接信息和db、table信息，先backup再restore

```shell
nohup sh ./backup.sh &
```

```shell
nohup sh ./restore.sh &
```

可以通过查看执行脚本目录下的backup_$(db}.log日志分析哪些表backup失败

失败关键字：

```text
Failed to execute the backup command in table：${tblName}
The table ${tblName} backup failed.
```

可以通过查看执行脚本目录下的restore_$(db_target}.log日志分析哪些表restore失败

失败关键字：

```text
Failed to execute the restore command in table：${tblName}
The snapshotname of the table ${tblName} does not exist!
The table ${tblName} restore is failed.
```

# 按照分区粒度备份和恢复
执行前需要修改对应的集群连接信息和db、table信息，先backup再restore

```shell
nohup sh ./backup_partitions.sh &
```
```shell
nohup sh ./restore_partitions.sh &
```

可以通过查看执行脚本目录下的backup_$(db}_pt.log日志分析哪些表backup失败

失败关键字：

```text
Failed to execute the backup command in table：${tblName}_${partitionName}
The table ${tblName}_${partitionName} backup failed.
```

可以通过查看执行脚本目录下的restore_$(db_target}_pt.log日志分析哪些表restore失败

失败关键字：

```text
The partition：${tblName}_${partitionName} snapshot ${snapshotname} not OK
Failed to execute the restore command in partition：${tblName}_${partitionName}
The snapshotname of the partition ${tblName}_${partitionName} does not exist!
The partition ${tblName}_${partitionName} restore is failed.
```

# 阿里云机器初始化脚本

```shell
sh ./init_ali.sh
```

# aws 机器初始化脚本

```shell
sh ./init_aws.sh
```
