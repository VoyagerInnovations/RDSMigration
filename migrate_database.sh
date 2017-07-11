#!/bin/bash

TODAY=`date +%Y%m%d`
POLICY_FILE_DIR=/home/ec2-user/RDSMigration
POLICY_FILE_NAME=$POLICY_FILE_DIR/rds_kms_policy.json

usage () {
  printf "\nUsage: migrate_database_updated.sh [-i <iam_user_name>] [-r <instance_role_name>] [-n <db_instance_identifier>] [-u <db_admin_user>] [-p <db_admin_passwd>] [-m <yes/no> ] [-d <db_name>] [-s <yes/no>] [-t <db_instance_class>] [-a <account_number>] [-z <region>]\n"
  printf "\nOptions:\n"
  echo "  -i <iam_user_name>            = IAM user who will administer the KMS key to be used in encrypting the database"
  echo "  -r <instance_role_name>       = IAM role of the instance that will access the encrypted RDS instance"
  echo "  -n <db_instance_identifier>   = (Source) RDS Instance Identifier"
  echo "  -u <db_admin_user>            = (Source) RDS DB Admin User"
  echo "  -p <db_admin_passwd>          = (Source) RDS DB Admin Password"
  echo "  -m <yes/no>                   = Indicate if the RDS instance contains multiple databases"
  echo "  -d <db_name>                  = Specify the database name. This option can be excluded/skipped if the value of '-m' is yes"
  echo "  -s <yes/no>                   = Indicate if the instance type of the (Source) RDS instance supports encryption"
  echo "  -t <db_instance_class>        = Specify the new DB instance class/type of the encrypted database. This option can be excluded/skipped if the value of '-s' is yes"
  echo "  -a <account_number>         = Specify the AWS account number where the resources resides"
  echo "  -z <region>           = Specify the AWS Region where the resources resides"
  printf "\nNote:\nThis script requires that you have the mysql and aws cli tools installed in your server.\nPlease ensure that the security group of source and destination RDS are properly configured before running the script.\n"
}

while getopts i:r:n:u:p:m:d:s:t:a:z:h option
do
 case "${option}"
 in
   i) IAM_USER_NAME=${OPTARG};;
   r) INSTANCE_ROLE_NAME=${OPTARG};;
   n) DB_INST_NAME=${OPTARG};;
   u) DB_ADMIN_USER=${OPTARG};;
   p) DB_ADMIN_PASSWD=${OPTARG};;
   m) DB_MULTIPLE_OPTION=${OPTARG};;
   d) DB_NAME=${OPTARG};;
   s) DB_INST_CLASS_SUPPORT_OPTION=${OPTARG};;
   t) DB_INSTANCE_CLASS_INPUT=${OPTARG};;
   a) ACCOUNT_NUM=${OPTARG};;
   z) REGION=${OPTARG};;
   h) usage
      exit
      ;;
 esac
done

if [ "$DB_MULTIPLE_OPTION" == "no" ]
then
  DB_NAME_PARAM="--db-name $DB_NAME"
else
  DB_NAME_PARAM=""
fi

# Describe Source Instance

echo "Getting the Source Database's Attributes..."

VPC_SECGRP_ID=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep VpcSecurityGroupId | awk -F':' '{print $2}' | sed 's/[", ]//g'`
PUBLICLY_ACCESSIBLE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep PubliclyAccessible | awk -F':' '{print $2}' | sed 's/[", ]//g'`
MULTI_AZ=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep MultiAZ | awk -F':' '{print $2}' | sed 's/[", ]//g'`
DB_PARAM_GRP_NAME=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep DBParameterGroupName | awk -F':' '{print $2}' | sed 's/[", ]//g'`
DB_SUBNET_GRP_NAME=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep DBSubnetGroupName | awk -F':' '{print $2}' | sed 's/[", ]//g'`
VPC_ID=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep VpcId | awk -F':' '{print $2}' | sed 's/[", ]//g'`
SRC_DB_ENDPT=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep Address | awk -F':' '{print $2}' | sed 's/[", ]//g'`
DB_INSTANCE_CLASS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep DBInstanceClass | awk -F':' '{print $2}' | sed 's/[", ]//g'`
ALLOCATED_STORAGE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep AllocatedStorage | awk -F':' '{print $2}' | sed 's/[", ]//g'`
STORAGE_TYPE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep StorageType | awk -F':' '{print $2}' | sed 's/[", ]//g'`
ENGINE_VERSION=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep EngineVersion | awk -F':' '{print $2}' | sed 's/[", ]//g'`
AVAILABILITY_ZONE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep AvailabilityZone | awk -F':' '{print $2}' | sed 's/[", ]//g'`
IOPS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep Iops | awk -F': ' '{print $2}' | sed 's/,//g'`
DB_TAGS_LIST=`aws rds list-tags-for-resource --resource-name arn:aws:rds:$REGION:$ACCOUNT_NUM:db:$DB_INST_NAME --region $REGION | grep Value -A 1 | sed '/--/d' | sed 's/[[:space:]]//g' | awk 'NR%2{printf "%s",$0;next;}1'`

if [ "$PUBLICLY_ACCESSIBLE" == "false" ]
then
  DB_PUBLICLY_ACCESSIBLE="--no-publicly-accessible"
else
  DB_PUBLICLY_ACCESSIBLE="--publicly-accessible"
fi

if [ "$MULTI_AZ" == "false" ]
then
  DB_MULTI_AZ="--no-multi-az"
else
  DB_MULTI_AZ="--multi-az"
fi

if [ "$IOPS" == '' ]
then
  DB_IOPS=""
else
  DB_IOPS="--iops $IOPS"
fi

# Create Read Replica
echo "Creating the read replica..."

aws rds create-db-instance-read-replica --db-instance-identifier $DB_INST_NAME-replica --source-db-instance-identifier $DB_INST_NAME --db-instance-class $DB_INSTANCE_CLASS --port 3306 $DB_PUBLICLY_ACCESSIBLE --storage-type $STORAGE_TYPE --copy-tags-to-snapshot --region $REGION

# Create KMS Key
echo "Creating KMS Key..."

sed "s/IAM_USER_NAME/$IAM_USER_NAME/g" $POLICY_FILE_NAME > $POLICY_FILE_DIR/rds_kms_$DB_INST_NAME.json
sed -i -e "s/INSTANCE_ROLE_NAME/$INSTANCE_ROLE_NAME/g" $POLICY_FILE_DIR/rds_kms_$DB_INST_NAME.json

KMS_KEY_ID=`aws kms create-key --description $DB_INST_NAME --key-usage ENCRYPT_DECRYPT --bypass-policy-lockout-safety-check --region $REGION --policy file://rds_kms_$DB_INST_NAME.json | grep KeyId | awk -F': ' '{print $2}' | sed 's/[",]//g'`
sleep 5
aws kms create-alias --alias-name alias/$DB_INST_NAME --target-key-id $KMS_KEY_ID --region $REGION
sleep 3

rm -f rds_kms_$DB_INST_NAME.json

# Create an Encrypted Database
echo "Creating encrypted database..."

if [ "$DB_INST_CLASS_SUPPORT_OPTION" == "no" ]
then
  DB_INSTANCE_CLASS=$DB_INSTANCE_CLASS_INPUT
fi

aws rds create-db-instance $DB_NAME_PARAM --db-instance-identifier $DB_INST_NAME-encrypted --allocated-storage $ALLOCATED_STORAGE --db-instance-class $DB_INSTANCE_CLASS --engine MySQL --master-username $DB_ADMIN_USER --master-user-password $DB_ADMIN_PASSWD --vpc-security-group-ids $VPC_SECGRP_ID --db-subnet-group-name $DB_SUBNET_GRP_NAME --db-parameter-group-name $DB_PARAM_GRP_NAME --port 3306 $DB_MULTI_AZ --engine-version $ENGINE_VERSION $DB_IOPS $DB_PUBLICLY_ACCESSIBLE --storage-type $STORAGE_TYPE --storage-encrypted --kms-key-id $KMS_KEY_ID --region $REGION

# Check replication status. If successful, stop replication
check_read_replica_status () {
  REPL_DB_INSTANCE_STATUS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-replica --region $REGION | grep DBInstanceStatus | awk -F':' '{print $2}' | sed 's/[", ]//g'`
  REPL_DB_ENDPT=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-replica --region $REGION | grep Address | awk -F':' '{print $2}' | sed 's/[", ]//g'`
}

check_read_replica_status
until [ "$REPL_DB_INSTANCE_STATUS" == "available" ]
do
  echo "Waiting for the read replica database to become available..."
  sleep 20
  check_read_replica_status
done

if [ "$REPL_DB_INSTANCE_STATUS" == "available" ]
then
  sleep 5
  echo "Stopping replication in read replica..."
  mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'CALL mysql.rds_stop_replication;'

  echo "Getting Master Log File and Position..."

  RELAY_MASTER_LOG_FILE=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'show slave status\G' | grep Relay_Master_Log_File | awk -F' ' '{print $2}'`
  EXEC_MASTER_LOG_POS=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'show slave status\G' | grep Exec_Master_Log_Pos | awk -F' ' '{print $2}'`

  echo Relay_Master_Log_File: $RELAY_MASTER_LOG_FILE
  echo Exec_Master_Log_Pos: $EXEC_MASTER_LOG_POS

  # Dump and Export Replica DB
  check_encrypted_db_status () {
    ENCRYPTED_DB_INSTANCE_STATUS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-encrypted --region $REGION | grep DBInstanceStatus | awk -F':' '{print $2}' | sed 's/[", ]//g'`
    ENCRYPTED_DB_ENDPT=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-encrypted --region $REGION | grep Address | awk -F':' '{print $2}' | sed 's/[", ]//g'`
  }

  check_encrypted_db_status
  until [ "$ENCRYPTED_DB_INSTANCE_STATUS" == "available" ]
  do
    echo "Waiting for the encrypted database to become available..."
    sleep 10
    check_encrypted_db_status
  done

  if [ "$REPL_DB_INSTANCE_STATUS" == "available" -a "$ENCRYPTED_DB_INSTANCE_STATUS" == "available" ]
  then
    echo "Tagging Replica and Encrypted DB..."
    for TAG in ${DB_TAGS_LIST[@]}
      do
        TAG_KEY=`echo $TAG | awk -F',' '{print $2}' | awk -F':' '{print $2}' | sed 's/"//g'`
        TAG_VALUE=`echo $TAG | awk -F',' '{print $1}' | awk -F':' '{print $2}' | sed 's/"//g'`

        aws rds add-tags-to-resource --resource-name arn:aws:rds:$REGION:$ACCOUNT_NUM:db:$DB_INST_NAME-replica --tags Key="$TAG_KEY",Value="$TAG_VALUE" --region $REGION
        aws rds add-tags-to-resource --resource-name arn:aws:rds:$REGION:$ACCOUNT_NUM:db:$DB_INST_NAME-encrypted --tags Key="$TAG_KEY",Value="$TAG_VALUE" --region $REGION
    done

    import_export_database () {
      echo "Executing DB Dump from Replica DB and DB Export to Encrypted DB $DB_NAME..."
      sleep 10
      time mysqldump -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT --verbose --single-transaction --quick --compress --databases $DB_NAME | pv -pterabc -N inbound | dd obs=16384K | dd obs=16384K | dd obs=16384K | dd obs=16384K | pv -pterabc -N outbound | mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT --compress
    }

    if [ "$DB_MULTIPLE_OPTION" == "yes" ]
    then
      DB_NAME_LIST=`mysql -u$DB_ADMIN_USER -h $REPL_DB_ENDPT -p$DB_ADMIN_PASSWD -e "show databases;" | grep -v information_schema | grep -v innodb | grep -v mysql | grep -v performance_schema | grep -v tmp | grep -v sys | grep -v Database`

      for SPEC_DB_NAME in ${DB_NAME_LIST[@]}
      do
        echo "Creating the $SPEC_DB_NAME database..."
        mysql -u$DB_ADMIN_USER -h $ENCRYPTED_DB_ENDPT -p$DB_ADMIN_PASSWD -e "CREATE DATABASE $SPEC_DB_NAME;"

        DB_NAME=$SPEC_DB_NAME
        import_export_database
      done
    else
      import_export_database
    fi
  fi

  # Copy Application Users
  DB_DETAILS_DIR=$POLICY_FILE_DIR/database_details
  mkdir -p $DB_DETAILS_DIR

  ## Get users from source database
  echo "Getting application users from source database to be loaded to the encrypted database..."

  mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e "SELECT USER, PASSWORD, HOST FROM mysql.user WHERE USER NOT IN ('rdsadmin', '$DB_ADMIN_USER', 'rdsrepladmin');" > $DB_DETAILS_DIR/$DB_INST_NAME-user.csv
  sed -i -e 's/[[:space:]]/,/g' $DB_DETAILS_DIR/$DB_INST_NAME-user.csv
  sed -i -e '1d' $DB_DETAILS_DIR/$DB_INST_NAME-user.csv

  IFS=$'\n'
  for USER_CREDS in $( cat $DB_DETAILS_DIR/$DB_INST_NAME-user.csv )
  do
    USERNAME=`echo $USER_CREDS | awk -F',' '{print $1}'`
    USER_PASSWD=`echo $USER_CREDS | awk -F',' '{print $2}'`
    USER_HOST=`echo $USER_CREDS | awk -F',' '{print $3}'`

    mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "CREATE USER '$USERNAME'@'$USER_HOST' IDENTIFIED BY PASSWORD '$USER_PASSWD';"

    ## Get user's grants and privileges

    mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e "SHOW GRANTS FOR '$USERNAME'@'$USER_HOST';" > $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
    sed -i -e '1d' $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
    sed -i -e "s/<secret>/'$USER_PASSWD'/g" $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
    sed -i -e 's/$/;/g' $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql

    mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT < $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
  done

  rm -f $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
  rm -f $DB_DETAILS_DIR/$DB_INST_NAME-user.csv

  # Create repl_user in Source Database
  echo "Creating replica user in source database..."

  mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "CREATE USER 'repl_user'@'%' IDENTIFIED BY '3&pZcHL5hM';"
  mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%' IDENTIFIED BY '3&pZcHL5hM';"

  # Setup and Start replication in Destination Encrypted Database
  echo "Setting up replication in encrypted database..."

  mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "CALL mysql.rds_set_external_master('$SRC_DB_ENDPT','3306','repl_user','3&pZcHL5hM','$RELAY_MASTER_LOG_FILE',$EXEC_MASTER_LOG_POS,0);"
  mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "CALL mysql.rds_start_replication;"

  sleep 5

  check_repl_encrypt_db_status () {
    CHECK_REPL_STATUS=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "SHOW SLAVE STATUS\G" | grep Slave_IO_State | awk -F': ' '{print $2}'`
    CHECK_REPL_ERROR=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "SHOW SLAVE STATUS\G" | grep Last_IO_Error: | awk -F':' '{print $2}'`
  }

  check_repl_encrypt_db_status
  until [ "$CHECK_REPL_STATUS" == "Waiting for master to send event" ]
  do
    check_repl_encrypt_db_status
  done

  if [ "$CHECK_REPL_STATUS" == "Waiting for master to send event" -a "$CHECK_REPL_ERROR" == ' '  ]
  then
    echo "Successful Replication."
    sleep 15

    # Rename the source db instance
    echo "Renaming DB instance name..."
    sleep 5
    aws rds modify-db-instance --db-instance-identifier $DB_INST_NAME --new-db-instance-identifier $DB_INST_NAME-old --apply-immediately --region $REGION

    # check if the new name took effect
    sleep 180
    check_srcdb_rename_status () {
      echo "Checking the existence of $DB_INST_NAME-old..."
      CHECK_SRCDB_RENAME=`aws rds describe-db-instances --region $REGION | grep '"DBInstanceIdentifier":' | grep $DB_INST_NAME-old`
      CHECK_SRCDB_RENAME_STAT=`echo $?`
    }

    check_srcdb_rename_status
    until [ $CHECK_SRCDB_RENAME_STAT -eq 0 ]
    do
      check_srcdb_rename_status
      sleep 60
    done

    if [ $CHECK_SRCDB_RENAME_STAT -eq 0 ]
    then
      check_rename_srcdb_availability_status () {
        CHECK_NEW_NAME=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-old --region $REGION | grep '"DBInstanceIdentifier":' | awk -F': ' '{print $2}' | sed 's/[", ]//g'`
        CHECK_RENAMED_SRCDB_STATUS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-old --region $REGION | grep DBInstanceStatus | awk -F':' '{print $2}' | sed 's/[", ]//g'`
      }

      check_rename_srcdb_availability_status
      until [ "$CHECK_RENAMED_SRCDB_STATUS" == "available" ]
      do
        check_rename_srcdb_availability_status
      done

      if [ "$CHECK_RENAMED_SRCDB_STATUS" == "available" -a "$CHECK_NEW_NAME" == "$DB_INST_NAME-old" ]
      then
        echo "Successfully renamed $DB_INST_NAME to $DB_INST_NAME-old."
        echo "Will proceed on renaming $DB_INST_NAME-encrypted to $DB_INST_NAME..."

        aws rds modify-db-instance --db-instance-identifier $DB_INST_NAME-encrypted --new-db-instance-identifier $DB_INST_NAME --apply-immediately --region $REGION
        sleep 180

        check_encryptdb_rename_status () {
          echo "Checking the existence of $DB_INST_NAME..."
          CHECK_ENCRYPTDB_RENAME=`aws rds describe-db-instances --region $REGION | grep '"DBInstanceIdentifier":' | grep $DB_INST_NAME`
          CHECK_ENCRYPTDB_RENAME_STAT=`echo $?`
        }

        check_encryptdb_rename_status
        until [ $CHECK_ENCRYPTDB_RENAME_STAT -eq 0 ]
        do
          check_encryptdb_rename_status
          sleep 20
        done

        if [ $CHECK_ENCRYPTDB_RENAME_STAT -eq 0 ]
        then
          check_rename_encryptdb_availability_status () {
            CHECK_RENAMED_ENCRYPTDB_STATUS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep DBInstanceStatus | awk -F':' '{print $2}' | sed 's/[", ]//g'`
          }

          check_rename_encryptdb_availability_status
          until [ "$CHECK_RENAMED_ENCRYPTDB_STATUS" == "available" ]
          do
            check_rename_encryptdb_availability_status
          done

          if [ "$CHECK_RENAMED_ENCRYPTDB_STATUS" == "available" ]
          then
            echo "Successfully renamed $DB_INST_NAME-encrypted to $DB_INST_NAME."

            # Cut replication in encrypted database
            sleep 30

            echo "Will proceed on stopping replication on encrypted database..."
            mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "CALL mysql.rds_stop_replication;"
            mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "CALL mysql.rds_reset_external_master;"

            echo "Done migrating your database to an encrypted one."
            echo "Please verify if your application can connect and be able to perform transactions to the encrypted database $DB_INST_NAME."
            echo "Once verified, kindly stop/delete the old instance $DB_INST_NAME-old."

            echo "For now, $DB_INST_NAME-replica will be deleted..."
            aws rds delete-db-instance --db-instance-identifier $DB_INST_NAME-replica --skip-final-snapshot --region $REGION
            echo "DONE."
          fi
        else
          check_encryptdb_rename_status
        fi
     fi
   else
     check_srcdb_rename_status
   fi
  else
    echo "There's an error in the replication."
    echo Slave_IO_State: $CHECK_REPL_STATUS
    echo Last_IO_Error: $CHECK_REPL_ERROR
    check_repl_encrypt_db_status
  fi
else
  check_read_replica_status
fi
