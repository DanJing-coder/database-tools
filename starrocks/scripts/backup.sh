      
#!/bin/bash

#数据库名
db=xxx
#fe ip，源集群
fe_ip=xxx
#root用户密码
password=xxx
#需要备份的表，表之间按照空格分开
tableList=(tb1 tb2 tb3)
#tableList=(${tables//,/ })
#正在操作的表
tblName=""
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

for i in ${tableList[@]}
    do
        tblName=$i
        snapshotname="snp_"${tblName}
        showbackup=`mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};show backup"`
        ifFinish=`echo ${showbackup} | grep -w ${snapshotname} |grep FINISHED | wc -l`
        
        if [[ -z "$showbackup" || ${ifFinish} -ne 1 ]]
        then
                `mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};BACKUP SNAPSHOT ${db}.${snapshotname} TO ${repositoryName} ON (${tblName}) PROPERTIES ('type' = 'full')"`
                if [[ $? -ne 0 ]]
                then
                        echo `date` "Failed to execute the backup command in table：${tblName}" >> backup_${db}.log
                        exit 0
                else
                        echo `date` "The backup command in table ${tblName} was successfully executed" >> backup_${db}.log
                fi
        fi
		
        while(true)
            do
                showbackup=`mysql -h ${fe_ip} -uroot -9030 -p${password} -e "use ${db};show backup"`
                if [[ ! -z "$showbackup" ]];then
                    ifFinish=`mysql -h ${fe_ip} -uroot -P9030 -p${password} -e "use ${db};show backup;"|grep -w ${snapshotname} | awk '{print $4}'`
                else
                    ifFinish="UPLOADING"
                fi
                if [[ "${ifFinish}" == "CANCELLED" ]];then
                    echo `date` "The table ${tblName} backup failed." >> backup_${db}.log
                    break
                elif  [[ "${ifFinish}" == "FINISHED" ]];then
                    echo `date` "The table ${tblName} backup success." >> backup_${db}.log
                    break
                else
                    echo `date` "The table ${tblName} backup is running." >> backup_${db}.log
                fi
                sleep ${interval}
            done
    done

echo "所有表都backup完成！"
exit 0

    
