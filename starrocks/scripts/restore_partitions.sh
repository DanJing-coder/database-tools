      
#!/bin/bash


#源集群 数据库名
db_source=xxx
#目标集群 数据库名
db_target=xxx
#fe ip，源集群ip
fe_ip_source=xxx
#fe ip，目标集群ip
fe_ip_target=xxx
#源集群 root用户密码
password_source=xxx
#目标集群 root用户密码
password_target=xxx
#需要restore的表
tblName=xxx
#获取需要restore表的所有分区
partitions=`mysql -h ${fe_ip_source} -uroot -P9030 -p${password_source} -e "use ${db_source};show partitions from ${tblName}" | awk 'NR!=1{print $2}'`
partitionList=($partitions)
#是否有制作好的镜像
snu_status=""
#
partitionName=xxx
#snapshot name
snapshotname=""
#snu_status状态是否为 FINISHED
ifFinish=""
#源集群 RepositoryName
RepositoryName_source=xxx
#目标集群 RepositoryName
RepositoryName_target=xxx
#间隔多久采集一次信息，默认20s
interval=20

for i in ${partitionList[@]}
    do
        partitionName=$i
		snapshotname="snp_"${tblName}_${partitionName}
		count=`mysql -h ${fe_ip_source} -uroot -P9030 -p${password_source} -e "use ${db_source};SHOW SNAPSHOT ON ${RepositoryName_source} WHERE SNAPSHOT = '${snapshotname}';"|grep "OK"|wc -l`
		if [[ ${count} -ne 1 ]];then
			echo `date` "The partition：${tblName}_${partitionName} snapshot ${snapshotname} not OK" >> restore_${db_target}.log
			continue
		fi

		timestamp=`mysql -h ${fe_ip_source} -uroot -P9030 -p${password_source} -e "use ${db_source};SHOW SNAPSHOT ON ${RepositoryName_source} WHERE SNAPSHOT = '${snapshotname}';" | awk 'NR==2{print}' | awk '{print $2}'`
		snu_status=`mysql -h ${fe_ip_source} -uroot -P9030 -p${password_source} -e "use ${db_source};SHOW SNAPSHOT ON ${RepositoryName_source} WHERE SNAPSHOT = '${snapshotname}';" | awk 'NR==2{print}' | awk '{print $3}'`
        


        if [[ -n "${timestamp}" && "${snu_status}" = "OK" ]]
        then
			`mysql -h ${fe_ip_target} -uroot -P9030 -p${password_target} -e "RESTORE SNAPSHOT ${db_target}.${snapshotname} FROM ${RepositoryName_target} ON (${tblName} PARTITION (${partitionName})) PROPERTIES ('backup_timestamp'='${timestamp}','replication_num' = '3');"`
			if [[ $? -ne 0 ]]
			then
					echo `date` "Failed to execute the restore command in partition：${tblName}_${partitionName}" >> restore_${db_target}_pt.log
					exit 0
			else
					echo `date` "The restore command in partition ${tblName}_${partitionName} was successfully executed!" >> restore_${db_target}_pt.log
			fi
		else
			echo `date` "The snapshotname of the partition ${tblName}_${partitionName} does not exist!" >> restore_${db_target}_pt.log
			exit 0
        fi
		
        ifFinish=`mysql -h ${fe_ip_target} -uroot -P9030 -p${password_target} -e "use ${db_target};SHOW restore from ${db_target};" | grep -w ${snapshotname} | awk '{print $5}'`

        while [[ "${ifFinish}" != "FINISHED" ]]
			do
				if [[ "${ifFinish}" == "CANCELLED" ]];then
					echo `date` "The partition ${tblName}_${partitionName} restore is failed." >> restore_${db_target}_pt.log
					break
				fi

				sleep ${interval}
				ifFinish=`mysql -h ${fe_ip_target} -uroot -P9030 -p${password_target} -e "use ${db_target};SHOW restore from ${db_target};" | grep -w ${snapshotname} | awk '{print $5}'`
				echo `date` "The partition ${tblName}_${partitionName} restore is running." >> restore_${db_target}_pt.log
			done
		if [[ "${ifFinish}" == "FINISHED" ]];then
			echo `date` "The partition ${tblName}_${partitionName} restore successfully" >> restore_${db_target}_pt.log
		fi
    done

echo "所有表都Restore完成！"
exit 0

    
