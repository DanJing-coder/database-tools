      
#!/bin/bash

#数据库名
db=xxx
#fe ip，源集群
fe_ip=xxx
#root用户密码
password=xxx
#需要备份的表
tblName=xxx
#分区名字，分区之间按照空格分开
partitions=`mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};show partitions from ${tblName}" | awk 'NR!=1{print $2}'`
partitionList=($partitions)
#tableList=(${tables//,/ })
#正在操作的表
partitionName=""
#执行结果
showbackup=""
#status状态是否为FINISHED
ifFinish=1
#status 状态是否为 UPLOADING
ifUpLoading=0
#snapshot name
snapshotname=""
#RepositoryName
repositoryName=xxx
#间隔多久采集一次信息，默认10s
interval=10

for i in ${partitionList[@]}
    do
        partitionName=$i
        snapshotname="snp_"${tblName}_${partitionName}
        showbackup=`mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};show backup"`
        ifFinish=`echo ${showbackup} | grep -w ${snapshotname} |grep FINISHED | wc -l`

        if [[ -z "$showbackup" || ${ifFinish} -ne 1 ]]
        then
                echo `mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};BACKUP SNAPSHOT ${db}.${snapshotname} TO ${repositoryName} ON (${tblName} PARTITION (${partitionName})) PROPERTIES ('type' = 'full')"`
                if [[ $? -ne 0 ]]
                then
                        echo `date` "Failed to execute the backup command in table：${tblName}_${partitionName}" >> backup_${db}.log
                        exit 0
                else
                        echo `date` "The backup command in table ${tblName}_${partitionName} was successfully executed" >> backup_${db}.log
                fi
        fi


        while(true)
            do
                showbackup=`mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};show backup"`
                if [[ ! -z "$showbackup" ]];then
                    ifFinish=`mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};show backup;"|grep -w ${snapshotname} | awk '{print $4}'`
                else
                    ifFinish="UPLOADING"
                fi
                if [[ "${ifFinish}" == "CANCELLED" ]];then
                    echo `date` "The table ${tblName}_${partitionName} backup failed." >> backup_${db}.log
                    break
                elif  [[ "${ifFinish}" == "FINISHED" ]];then
                    echo `date` "The table ${tblName}_${partitionName} backup success." >> backup_${db}.log
                    break
                else
                    echo `date` "The table ${tblName}_${partitionName} backup is running." >> backup_${db}.log
                fi
                sleep ${interval}
            done
    done

echo "所有表都backup完成！"
exit 0

    
