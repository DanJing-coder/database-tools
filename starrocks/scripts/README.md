# starrocks 基础环境检查脚本
需要打通执行该脚本的节点到其他节点的ssh免密

```shell
sh ./env_check.sh -h$fe_ip -uroot -P9030 -pxxx
```

# 检查be节点的brpc是否卡住，并打印stack
修改对应的参数

```shell
nohup sh ./check_brpc.sh 2>&1 >> brpc.log
```

# 检查fe是否死锁并自动重启

```shell
nohup sh ./check_deadlock.sh 2>&1 >> deadlock.log
```

# 阿里云机器初始化脚本

```shell
sh ./init_ali.sh
```

# aws 机器初始化脚本

```shell
sh ./init_aws.sh
```
