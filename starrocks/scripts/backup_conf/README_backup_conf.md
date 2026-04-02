# StarRocks 配置备份工具

## 概述
`backup_conf.sh` 是一个用于远程备份 StarRocks 集群中 FE、BE 和 Broker 节点配置文件的 Shell 脚本工具。该工具可以根据用户指定的组件类型和节点列表，自动获取各组件的配置目录并备份到与原配置目录同级的位置。

## 功能特性

1. 支持备份 FE、BE 和 Broker 组件的配置文件
2. 自动识别节点连接状态，跳过无法连接的节点
3. 支持从文件或直接指定节点列表，兼容逗号分隔和换行分隔两种格式
4. 对每个组件使用不同的路径获取方法，确保准确性
5. 备份目录自动添加日期后缀，避免覆盖
6. 提供详细的彩色输出日志，便于监控执行过程
7. 在远程节点直接使用cp命令进行备份，不需要复制到本地
8. 支持配置对比功能，可对比备份配置与原配置的差异，并显示文件内容的具体差异（使用统一差异格式）

## 安装与使用

### 环境要求
- Linux 或 macOS 系统（或 Windows 系统下的 WSL、Git Bash 等环境）
- SSH 服务（用于远程连接节点）
- 目标节点需要设置免密登录

### 使用方法

基本语法：
```bash
./backup_conf.sh [选项] <组件类型> <目标>
```

#### 参数说明
- `组件类型`：要备份的组件类型，可以是 `be`、`fe`、`broker` 或它们的组合（用逗号分隔，如 `be,fe`）
- `目标`：节点列表文件（每行一个节点或用逗号分隔的节点）或单个节点主机名/IP

#### 选项
- `-h`：显示帮助信息
- `-c`：启用只对比不备份功能，直接对比当前配置与最近备份的配置差异，并显示文件内容的具体差异（使用统一差异格式）

## 路径获取逻辑

该脚本使用以下方法获取各组件的安装路径：

### BE 路径获取
通过进程信息提取 BE 安装路径：
```bash
ps -ef | grep starrocks_be | grep -v grep | grep -v gdb | awk '{print $8}' | sed 's/\/lib.*//' | head -n 1
```

### FE 路径获取
根据用户提供的方法，从 JVM 参数中提取 FE 安装路径：
```bash
ps -ef | grep "com.starrocks.StarRocksFE" | grep -v "grep" | grep -oP '(?<=-Xlog:gc\*:).*(?=/log/fe\.gc\.log)'
```

### Broker 路径获取
根据用户提供的方法，从进程信息中提取 Broker 安装路径：
```bash
ps -ef | grep start_broker | grep -v "grep" | grep -oP '(?<=bash\s).+(?=/bin/)'
```

## 配置目录路径

各组件的配置目录路径为：
- BE 配置目录：`${be_path}/conf`
- FE 配置目录：`${fe_path}/conf`
- Broker 配置目录：`${broker_path}/conf`

## 使用示例

### 使用示例

1. 备份多个 BE 节点的配置文件

假设有一个包含多个 BE 节点的文件 `be_nodes.txt`，每行一个节点 IP：
```
192.168.1.101
192.168.1.102
192.168.1.103
```

export命令：
```bash
./backup_conf.sh be be_nodes.txt
```

2. 备份单个节点的 FE 和 BE 配置

```bash
./backup_conf.sh be,fe 192.168.1.200
```

3. 备份多个以逗号分隔的 Broker 节点

假设有一个文件 `broker_nodes.txt`，内容为：
```
192.168.1.201,192.168.1.202,192.168.1.203
```

export命令：
```bash
./backup_conf.sh broker broker_nodes.txt
```

4. 只对比不备份，直接对比配置差异：
```bash
./backup_conf.sh -c be,fe 192.168.1.200
```
此命令会对比当前配置与最近备份的配置差异，但不会执行新的备份操作。

## 备份目录命名规则

备份目录命名格式为：
```
conf_backup_<日期>
```

其中日期格式为 `YYYYMMDD`，例如：
```
/starrocks/be/conf_backup_20231115
/starrocks/fe/conf_backup_20231115
/starrocks/broker/conf_backup_20231115
```

备份目录位于与原配置目录同级的位置。

## 注意事项

1. 确保所有目标节点都已配置免密登录，否则脚本将无法连接并跳过备份
2. 如果无法获取组件的安装路径，脚本会自动跳过该组件的备份
3. 备份过程中，如果目标备份目录已存在，脚本会先删除该目录再进行备份
4. 当前脚本主要设计用于 Linux 环境，在 Windows 环境下可能需要安装额外的工具如 Git Bash 或 WSL
5. 备份文件存储在与原配置目录同级的位置，不需要额外的本地存储空间