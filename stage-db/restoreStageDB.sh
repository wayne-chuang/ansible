#! /bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

# 參數區..
OriginDBName=kkday-prod-postgresql
NewDBName=postgresql.stage1.kkday.com
InstanceClass=db.t2.medium
StorageType=io1
IOPS=1000
SecurityGroups="sg-7947391c sg-4de48329"
ParameterGroup=kkday-postgresql-93
NewPassword=stage.postgresql.nn{7DzWcxPh9X5)!
IsCreateUser=true

#OriginDBName=kkday-prod-mysql-session
#NewDBName=kkday-snapshot-mysql-session
#InstanceClass=db.t2.medium
#StorageType=gp2
#SecurityGroups="sg-7947391c sg-9a443aff"
#ParameterGroup=kkday-mysql
#NewPassword=9wQaf5ME
#IsCreateUser=false

echo ''
echo '=============================================================================='
echo ''

echo 'restore start !' $(date +"%Y-%m-%d %H:%M:%S")

# Delete Old DB
if [ $(aws rds describe-db-instances | jq '.DBInstances [].DBInstanceIdentifier' -r | grep "^${NewDBName}$" | wc -l) == 1 ]; then
    echo 'delete old database'
    aws rds delete-db-instance --db-instance-identifier ${NewDBName} --skip-final-snapshot
    sleep 30
fi

# Waiting for Delete DB
IsDelete=false
MaxIdle=3600
WaitSec=0
while [ $IsDelete == false -a $WaitSec -lt $MaxIdle ]; do
    if [ $(aws rds describe-db-instances | jq '.DBInstances [].DBInstanceIdentifier' -r | grep "^${NewDBName}$" | wc -l) == 0 ]; then
       echo 'DB is Deleted'
       IsDelete=true
    else
       sleep 60
       echo 'not available, continue waiting ...'
       let WaitSec=WaitSec+60
       echo $WaitSec
    fi
done

if [ $IsDelete == false ]; then
    exit 1
fi

# Find Snapshot
SnapshotName=$(aws rds describe-db-snapshots --db-instance-identifier ${OriginDBName} --snapshot-type automated | jq '.DBSnapshots | max_by(.SnapshotCreateTime) | .DBSnapshotIdentifier' -r)

if [ -z "$SnapshotName" ]; then
    echo "Can't find Snapshot"
    exit 1
elif [ "$SnapshotName" == "null" ]; then
    echo "Can't find Snapshot"
    exit 1
fi

echo "find SnapshotName = $SnapshotName"

# Restore DB
echo 'restore DB'

if [ "$StorageType" == "io1" ]; then
    aws rds restore-db-instance-from-db-snapshot --db-instance-identifier ${NewDBName} --db-snapshot-identifier ${SnapshotName} --db-instance-class ${InstanceClass} --storage-type ${StorageType} --iops ${IOPS} --no-multi-az --availability-zone ap-northeast-1a --db-subnet-group-name rds-vpc --publicly-accessible
else
    aws rds restore-db-instance-from-db-snapshot --db-instance-identifier ${NewDBName} --db-snapshot-identifier ${SnapshotName} --db-instance-class ${InstanceClass} --storage-type ${StorageType} --no-multi-az --availability-zone ap-northeast-1a --db-subnet-group-name rds-vpc --publicly-accessible
fi

sleep 30

# Waiting for Restore DB
IsAvailable=false
MaxIdle=3600
WaitSec=0
while [ $IsAvailable == false -a $WaitSec -lt $MaxIdle ]; do
    if [ $(aws rds describe-db-instances --db-instance-identifier ${NewDBName} | jq '.DBInstances[0].DBInstanceStatus' -r) == available ]; then
       echo 'DB status = available'
       IsAvailable=true
    else
       sleep 60
       echo 'not available, continue waiting ...'
       let WaitSec=WaitSec+60
       echo $WaitSec
    fi
done

if [ $IsAvailable == false ]; then
    exit 1
fi

# 因為自動備份的 snapshot 都會包含原始的 tag, 沒辦法用 tag 來做權限控管, 改使用 Resource 跟 Condition 來做權限控管

# Modify Database => Add Tag
#echo 'add tag to DB'
#aws rds add-tags-to-resource --resource-name "arn:aws:rds:ap-northeast-1:595659141358:db:${NewDBName}" --tags "Key=env,Value=snapshot"
#sleep 300

# 這邊很弔詭的直接確認有 tag 就作業會權限不足, 只好強制等 5 分鐘 ... (30 秒不夠)

# Wait for Add Tag
#IsFindTag=false
#MaxIdle=600
#WaitSec=0
#while [ $IsFindTag == false -a $WaitSec -lt $MaxIdle ]; do
#    if [ "$(aws rds list-tags-for-resource --resource-name "arn:aws:rds:ap-northeast-1:595659141358:db:${NewDBName}" | jq '.TagList[] | select(.Key == "env")  | select(.Value == "snapshot") | .Value' -r)" == "snapshot" ]; then
#       echo 'Tag is Added'
#       IsFindTag=true
#    else
#       sleep 60
#       echo 'not find Tag, continue waiting ...'
#       let WaitSec=WaitSec+60
#       echo $WaitSec
#    fi
#done

#if [ $IsFindTag == false ]; then
#    exit 1
#fi


# Modify Database => Change Security Groups & Parameter Group
echo 'modify Security Groups & Parameter Group'
aws rds modify-db-instance --db-instance-identifier ${NewDBName} --master-user-password ${NewPassword} --vpc-security-group-ids ${SecurityGroups} --db-parameter-group-name ${ParameterGroup} --no-apply-immediately
sleep 30

# Wait for Modify DB
IsAvailable=false
MaxIdle=3600
WaitSec=0
while [ $IsAvailable == false -a $WaitSec -lt $MaxIdle ]; do
    if [ $(aws rds describe-db-instances --db-instance-identifier ${NewDBName} | jq '.DBInstances[0].DBInstanceStatus' -r) == available ]; then

        if [ "$(aws rds describe-db-instances --db-instance-identifier ${NewDBName} | jq '.DBInstances[0].DBParameterGroups[] | select(.DBParameterGroupName == '\"${ParameterGroup}\"') | select(.ParameterApplyStatus == "pending-reboot") | .ParameterApplyStatus' -r)" == "pending-reboot" ]; then
            echo 'DB status = available'
            IsAvailable=true
        else
            sleep 60
            echo 'not available, continue waiting ...'
            let WaitSec=WaitSec+60
            echo $WaitSec
        fi

    else
       sleep 60
       echo 'not available, continue waiting ...'
       let WaitSec=WaitSec+60
       echo $WaitSec
    fi
done

if [ $IsAvailable == false ]; then
    exit 1
fi

# Reboot DB
echo 'reboot DB'
aws rds reboot-db-instance --db-instance-identifier ${NewDBName}
sleep 30

# Wait for Reboot DB
IsAvailable=false
MaxIdle=3600
WaitSec=0
while [ $IsAvailable == false -a $WaitSec -lt $MaxIdle ]; do
    if [ $(aws rds describe-db-instances --db-instance-identifier ${NewDBName} | jq '.DBInstances[0].DBInstanceStatus' -r) == available ]; then
       echo 'DB status = available'
       IsAvailable=true
    else
       sleep 60
       echo 'not available, continue waiting ...'
       let WaitSec=WaitSec+60
       echo $WaitSec
    fi
done

if [ $IsAvailable == false ]; then
    exit 1
fi


# Excute PSQL to Create User
if [ "$IsCreateUser" == true ]; then

    NewDBEndPoint=$(aws rds describe-db-instances --db-instance-identifier ${NewDBName} | jq '.DBInstances[0].Endpoint.Address' -r)
    # 使用者清單, 注意第二個 item 之後要有逗號 (JSON 格式)
    UserList='['
    UserList=$UserList'{"username":"kk_dbaman", "password":"stage.dbaman.4UYeC_XPr7Q2eSpN"}'
    UserList=$UserList',{"username":"kk_sche_admin", "password":"sche.admin.vzby&`3E:s,5J+@="}'
    UserList=$UserList',{"username":"apiuser", "password":"api.{XDn3-9yVTyuW>h("}'
    UserList=$UserList',{"username":"acctdoc_api_user", "password":"acctdoc.api.user.cXUTnxuQx*2xCWqm"}'
    UserList=$UserList',{"username":"it_team_data", "password":"data.team.6LFcff_TuB_3@w5z"}'
    UserList=$UserList',{"username":"it_team_fa", "password":"fa.team.ZzL8ShD8YTy_A3Ln"}'
    UserList=$UserList',{"username":"fa_api_user", "password":"api.user.j7uRFWD+kKv!7nvZ"}'
    UserList=$UserList',{"username":"wh_api_user", "password":"api.user.JmXTMHtrFB5&z8b*"}'
    UserList=$UserList']'

    Count=$(printf "$UserList" | jq '. | length')

    for ((i=0; i<Count; i++))
    {
        _username=$(printf "$UserList" | jq ".[$i].username" -r)
        _password=$(printf "$UserList" | jq ".[$i].password" -r)

        export PGPASSWORD=$NewPassword
        psql --host=${NewDBEndPoint} --username=kkdayadmin --dbname=kkdb -c "﻿ALTER USER ${_username} PASSWORD '${_password}' ;"
        export PGPASSWORD=
    }
fi

# Backup to S3
pg_dump --host=postgresql-snapshot.kkday.com kkdb --username=kk_sche_admin --schema=public --exclude-table-data='acctdoc_*|affilliate_order|affilliate_settle|affilliate_settle_pay|channel_order_*|comm_batch|comm_log_*|comm_mail|comm_mail_attach|comm_mail_inline|http_job|marketing_order|order_*|pmch*|pmgw_record|imp_ga_prod_pv|message|miles_send|miles_receive|trans_log|trans_batch|product_snap|product_rank|product_recommand' --format=tar --encoding=UTF8 --verbose --file=/data/prod-db-qc.tar

gzip /data/prod-db-qc.tar

aws s3api put-object --bucket kkday-deploy --key db_backup/prod-db-qc.tar.gz --body /data/prod-db-qc.tar.gz

rm /data/prod-db-qc.tar.gz


# Create Analytics Tables for Tableau
#SNAPSHOT_SQL_FOLDER=/data/shell/Database/snapshot-sql

#psql --host=postgresql-snapshot.kkday.com --username=kk_sche_admin --dbname=kkdb -f ${SNAPSHOT_SQL_FOLDER}/schema_prod_20180223.sql > /dev/null
#psql --host=postgresql-snapshot.kkday.com --username=kk_sche_admin --dbname=kkdb -f ${SNAPSHOT_SQL_FOLDER}/schema_channel_20171211.sql > /dev/null
#psql --host=postgresql-snapshot.kkday.com --username=kk_sche_admin --dbname=kkdb -f ${SNAPSHOT_SQL_FOLDER}/schema_bdop_20180306.sql > /dev/null

#psql --host=postgresql-snapshot.kkday.com --username=apiuser --dbname=kkdb -f ${SNAPSHOT_SQL_FOLDER}/data_prod_20180223.sql > /dev/null
#psql --host=postgresql-snapshot.kkday.com --username=apiuser --dbname=kkdb -f ${SNAPSHOT_SQL_FOLDER}/data_channel_20171211.sql > /dev/null
#psql --host=postgresql-snapshot.kkday.com --username=apiuser --dbname=kkdb -f ${SNAPSHOT_SQL_FOLDER}/data_bdop_20180306.sql > /dev/null



echo 'restore end !' $(date +"%Y-%m-%d %H:%M:%S")
echo ''                