# upgradeClusterManual 目录说明

本目录包含 BE 升级与集群启动/重启脚本，用于手工运维场景的快速执行。建议先阅读并测试脚本在小规模环境中再上线生产。

## 脚本列表

- `be_upgrade_tool.sh`：BE 升级/备份/回滚工具
- `start_srop_restart_cluster.sh`：基于 agentctl 的 BE 启停/重启工具

---

## 1. be_upgrade_tool.sh

### 功能
- backup：备份目标目录（默认 `lib`）为 `lib_<suffix>`
- upload：全量替换目标目录（默认 `lib`），并将当前目录重命名为 `*_replaced_*`
- rollback：从指定备份目录回滚至目标目录

### 参数
- `-m <backup|upload|rollback>`
- `-d <远程目标目录>`（默认 `lib`）
- `-f <本地源文件或目录>`（upload 模式必填）
- `-v <版本后缀>`（默认当前月日，如 `0627`）
- `<hosts_file>`：BE节点列表，支持逗号或换行格式

### 使用示例
```bash
./be_upgrade_tool.sh -m backup -d lib -v 0627 be_nodes.txt
./be_upgrade_tool.sh -m upload -d lib -f /tmp/new_lib be_nodes.txt
./be_upgrade_tool.sh -m rollback -d lib -v 0627 be_nodes.txt
```

注意：
- upload 模式后需手动重启 BE；
- 需先确认 `ssh` 免密可用；
- 出现失败请检查远程路径和 BE 目录权限。

---

## 2. start_srop_restart_cluster.sh

### 功能
基于 agentctl 操作集群节点：start/stop/restart

### 参数
- `-s`：执行 start
- `-t`：执行 stop
- `-r`：执行 restart（默认）
- `<节点文件|单节点>`：可用文件或单个主机名/IP

### 使用示例
```bash
./start_srop_restart_cluster.sh -r be_nodes.txt
./start_srop_restart_cluster.sh -s 192.168.1.100
```

### 要点
- 支持文件内逗号分隔或换行分隔
- 自动从进程查找 `agentctl.sh` 路径
- 操作时会验证 agent 可用性
- 失败节点会跳过并继续

---

## 维护建议
- 执行前先备份当前配置与运行目录
- 升级/回滚脚本应配合监控与版本校验使用
- 生产环境先单节点验证，再批量执行
