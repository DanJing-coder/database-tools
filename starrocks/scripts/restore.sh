      
#!/bin/bash


#源集群数据库名
db_source=xxx
#目标集群数据库名
db_target=xxx
#fe ip，源集群ip
fe_ip_=xxx
#fe ip，目标集群ip
fe_ip_target=xxx
#源集群 root用户密码
password_source=xxx
#目标集群 root用户密码
password_target=xxx
#需要备份的表，表之间按照空格分开
tableList=(tb1 tb2 tb3)
tblName=""
#是否有制作好的镜像
snu_status=""
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

for i in ${tableList[@]}
    do
        tblName=$i
		snapshotname="snp_"${tblName}
		timestamp=`mysql -h ${fe_ip_source} -uroot -P9030 -p${password_source} -e "use ${db_source};SHOW SNAPSHOT ON ${RepositoryName_source} WHERE SNAPSHOT = '${snapshotname}';" | awk 'NR==2{print}' | awk '{print $2}'`
		snu_status=`mysql -h ${fe_ip_source} -uroot -P9030 -p${password_source} -e "use ${db_source};SHOW SNAPSHOT ON ${RepositoryName_source} WHERE SNAPSHOT = '${snapshotname}';" | awk 'NR==2{print}' | awk '{print $3}'`
        
        if [[ -n "${timestamp}" && "${snu_status}" = "OK" ]]
        then
			`mysql -h ${fe_ip_target} -uroot -P9030 -p${password_target} -e "RESTORE SNAPSHOT ${db_target}.${snapshotname} FROM ${RepositoryName_target} ON (${tblName}) PROPERTIES ('backup_timestamp'='${timestamp}','replication_num' = '3');"`
			if [[ $? -ne 0 ]]
			then
					echo `date` "Failed to execute the restore command in table：${tblName}" >> restore_${db_target}.log
					exit 0
			else
					echo `date` "The restore command in table ${tblName} was successfully executed!" >> restore_${db_target}.log
			fi
		else
			echo `date` "The snapshotname of the table ${tblName} does not exist!" >> restore_${db_target}.log
			exit 0
        fi
		
        ifFinish=`mysql -h ${fe_ip_target} -uroot -P9030 -p${password_target} -e "use ${db_target};SHOW restore from ${db_target};" | grep -w ${snapshotname} | awk '{print $5}'`

        while [[ "${ifFinish}" != "FINISHED" ]]
			do
				if [[ "${ifFinish}" == "CANCELLED" ]];then
					echo `date` "The table ${tblName} restore is failed." >> restore_${db_target}.log
					continue
				fi

				sleep ${interval}
				ifFinish=`mysql -h ${fe_ip_target} -uroot -P9030 -p${password_target} -e "use ${db_target};SHOW restore from ${db_target};" | grep -w ${snapshotname} | awk '{print $5}'`
				echo `date` "The table ${tblName} restore is running." >> restore_${db_target}.log
			done
		if [[ "${ifFinish}" == "FINISHED" ]];then
			echo `date` "The table ${tblName} restore successfully" >> restore_${db_target}.log
		fi
    done

echo "所有表都Restore完成！"
exit 0

    
