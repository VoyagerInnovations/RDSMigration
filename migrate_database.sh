#!/bin/bash

TODAY=`date +%Y%m%d`
POLICY_FILE_DIR=/home/ec2-user/RDSMigration
POLICY_FILE_NAME=$POLICY_FILE_DIR/rds_kms_policy.json
INSTANCE_CLASS_LIST=$POLICY_FILE_DIR/instance_types.csv

usage () {
  printf "\nUsage: migrate_database.sh [-i <iam_user_name>] [-r <instance_role_name>] [-n <db_instance_identifier>] [-u <db_admin_user>] [-p <db_admin_passwd>] [-m <yes/no> ] [-d <db_name>] [-a <account_number>] [-z <region_name>]\n"
  printf "\nOptions:\n"
  echo "  -i <iam_user_name>            = IAM user who will administer the KMS key to be used in encrypting the database"
  echo "  -r <instance_role_name>       = IAM role of the instance that will access the encrypted RDS instance"
  echo "  -n <db_instance_identifier>   = (Source) RDS Instance Identifier"
  echo "  -u <db_admin_user>            = (Source) RDS DB Admin User"
  echo "  -p <db_admin_passwd>          = (Source) RDS DB Admin Password"
  echo "  -m <yes/no>                   = Indicate if the RDS instance contains multiple databases"
  echo "  -d <db_name>                  = Specify the database name. This option can be excluded/skipped if the value of '-m' is yes"
  echo "  -a <account_number>         	= Specify the AWS account number where the resources resides"
  echo "  -z <region_name>           	= Specify the AWS Region where the resources resides"
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

# Flight Check

## Check IAM roles and permissions

## Check Packages
CHECK_AWSCLI=`rpm -qa | grep aws-cli`
CHECK_AWSCLI_STAT=`echo $?`
CHECK_MYSQL=`rpm -qa | grep mysql`
CHECK_MYSQL_STAT=`echo $?`

if [ $CHECK_AWSCLI_STAT -eq 0 -a $CHECK_MYSQL_STAT -eq 0 ]
then
 echo "Packages required are already installed. Okay to proceed..."
else
 echo "Please install the required packages: mysql and aws-cli."
 exit
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

CHECK_INSTANCE_TYPE=`cat $INSTANCE_CLASS_LIST | grep $DB_INSTANCE_CLASS`
CHECK_INSTANCE_STAT=`echo $?`

if [ $CHECK_INSTANCE_STAT -eq 0 ]
then
  echo "The Source Database's instance class supports encryption. Okay to proceed..."
else
  printf "The Source Database's instance class doesn't support encryption.\nKindly see the link for the list of instance type that supports encryption: http://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Overview.Encryption.html\n"
  echo "To proceed, please input the desired instance class:"
  read NEW_INSTANCE_CLASS 
  DB_INSTANCE_CLASS=$NEW_INSTANCE_CLASS
fi

# Create Read Replica
echo "Creating the read replica..."

CREATE_DB_READ_REPL=`aws rds create-db-instance-read-replica --db-instance-identifier $DB_INST_NAME-replica --source-db-instance-identifier $DB_INST_NAME --db-instance-class $DB_INSTANCE_CLASS --port 3306 $DB_PUBLICLY_ACCESSIBLE --storage-type $STORAGE_TYPE --copy-tags-to-snapshot --region $REGION`
CREATE_DB_READ_REPL_STAT=`echo $?`

if [ $CREATE_DB_READ_REPL_STAT -eq 0 ]
then
  echo "$DB_INST_NAME-replica has been successfully created."
else
  echo "Failed to create the DB Read Replica."
  exit
fi

# Create KMS Key
echo "Creating KMS Key..."

sed "s/IAM_USER_NAME/$IAM_USER_NAME/g" $POLICY_FILE_NAME > $POLICY_FILE_DIR/rds_kms_$DB_INST_NAME.json
sed -i -e "s/INSTANCE_ROLE_NAME/$INSTANCE_ROLE_NAME/g" $POLICY_FILE_DIR/rds_kms_$DB_INST_NAME.json

KMS_KEY_ID=`aws kms create-key --description $DB_INST_NAME --key-usage ENCRYPT_DECRYPT --bypass-policy-lockout-safety-check --region $REGION --policy file://rds_kms_$DB_INST_NAME.json | grep KeyId | awk -F': ' '{print $2}' | sed 's/[",]//g'`
KMS_KEY_STAT=`echo $?`

if [ $KMS_KEY_STAT -eq 0 ]
then
  echo "Successfully created KMS key $KMS_KEY_ID."
  sleep 5
  CREATE_KMS_ALIAS=`aws kms create-alias --alias-name alias/$DB_INST_NAME --target-key-id $KMS_KEY_ID --region $REGION`
  CREATE_KMS_ALIAS_STAT=`echo $?`

  if [ $CREATE_KMS_ALIAS_STAT -eq 0 ]
  then
    echo "Successfully created KMS Alias $DB_INST_NAME."
    rm -f $POLICY_FILE_DIR/rds_kms_$DB_INST_NAME.json
  else
    echo "Failed to create the KMS Alias."
    exit
  fi
else
  echo "Failed to create the KMS Key."
  exit
fi
  
# Create an Encrypted Database
echo "Creating encrypted database..."

#if [ "$DB_INST_CLASS_SUPPORT_OPTION" == "no" ]
#then
#  DB_INSTANCE_CLASS=$DB_INSTANCE_CLASS_INPUT
#fi

CREATE_DB_ENCRYPTED=`aws rds create-db-instance $DB_NAME_PARAM --db-instance-identifier $DB_INST_NAME-encrypted --allocated-storage $ALLOCATED_STORAGE --db-instance-class $DB_INSTANCE_CLASS --engine MySQL --master-username $DB_ADMIN_USER --master-user-password $DB_ADMIN_PASSWD --vpc-security-group-ids $VPC_SECGRP_ID --db-subnet-group-name $DB_SUBNET_GRP_NAME --db-parameter-group-name $DB_PARAM_GRP_NAME --port 3306 $DB_MULTI_AZ --engine-version $ENGINE_VERSION $DB_IOPS $DB_PUBLICLY_ACCESSIBLE --storage-type $STORAGE_TYPE --storage-encrypted --kms-key-id $KMS_KEY_ID --region $REGION`
CREATE_DB_ENCRYPTED_STAT=`echo $?`

if [ $CREATE_DB_ENCRYPTED_STAT -eq 0 ]
then
  echo "Successfully created Encrypted Database $DB_INST_NAME-encrypted." 
else
  echo "Failed to create the encrypted database."
  exit
fi

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
  EXEC_STOP_REPLICATION=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'CALL mysql.rds_stop_replication;'`
  EXEC_STOP_REPLICATION_STAT=`echo $?`

  if [ $EXEC_STOP_REPLICATION_STAT -eq 0 ]
  then
    echo "Successfully stopped replication in $DB_INST_NAME-replica."
    echo "Getting Master Log File and Position..."

    RELAY_MASTER_LOG_FILE=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'show slave status\G' | grep Relay_Master_Log_File | awk -F' ' '{print $2}'`
    RELAY_MASTER_LOG_FILE_STAT=`echo $?`
    EXEC_MASTER_LOG_POS=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'show slave status\G' | grep Exec_Master_Log_Pos | awk -F' ' '{print $2}'`
    EXEC_MASTER_LOG_POS_STAT=`echo $?`

    if [ $RELAY_MASTER_LOG_FILE_STAT -eq 0 -a $EXEC_MASTER_LOG_POS_STAT -eq 0 ]
    then
      echo Relay_Master_Log_File: $RELAY_MASTER_LOG_FILE
      echo Exec_Master_Log_Pos: $EXEC_MASTER_LOG_POS
    else
      echo "Failed to get Master Log File and Position."
      exit
    fi
  else
    echo "Failed to stop replication in $DB_INST_NAME-replica."
    exit
  fi


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
      MIGRATE_DBS=`time mysqldump -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT --verbose --single-transaction --quick --compress --databases $DB_NAME | pv -pterabc -N inbound | dd obs=16384K | dd obs=16384K | dd obs=16384K | dd obs=16384K | pv -pterabc -N outbound | mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT --compress`
      MIGRATE_DBS_STAT=`echo $?`

      if [ $MIGRATE_DBS_STAT -eq 0 ]
      then
        echo "Successfully migrated the database." 
      else
        echo "Failed to migrate the database."
	exit
      fi
    }

    if [ "$DB_MULTIPLE_OPTION" == "yes" ]
    then
      DB_NAME_LIST=`mysql -u$DB_ADMIN_USER -h $REPL_DB_ENDPT -p$DB_ADMIN_PASSWD -e "show databases;" | grep -v information_schema | grep -v innodb | grep -v mysql | grep -v performance_schema | grep -v tmp | grep -v sys | grep -v Database`

      for SPEC_DB_NAME in ${DB_NAME_LIST[@]}
      do
        echo "Creating the $SPEC_DB_NAME database..."
        CREATE_SPEC_DATABASE=`mysql -u$DB_ADMIN_USER -h $ENCRYPTED_DB_ENDPT -p$DB_ADMIN_PASSWD -e "CREATE DATABASE $SPEC_DB_NAME;"`
	CREATE_SPEC_DATABASE_STAT=`echo $?`

        if [ $CREATE_SPEC_DATABASE_STAT -eq 0 ]
	then
	  echo "Successfully created $SPEC_DB_NAME database."
          DB_NAME=$SPEC_DB_NAME
          import_export_database
	else
	  echo "Failed to create $SPEC_DB_NAME database."
	  exit
	fi
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

    CREATE_MYSQL_USER=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "CREATE USER '$USERNAME'@'$USER_HOST' IDENTIFIED BY PASSWORD '$USER_PASSWD';"`
    CREATE_MYSQL_USER_STAT=`echo $?`

    if [ $CREATE_MYSQL_USER_STAT -eq 0 ]
    then
      echo "Successfully created $USERNAME user."

      ## Get user's grants and privileges
      mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e "SHOW GRANTS FOR '$USERNAME'@'$USER_HOST';" > $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
      sed -i -e '1d' $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
      sed -i -e "s/<secret>/'$USER_PASSWD'/g" $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
      sed -i -e 's/$/;/g' $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql

      IMPORT_USERGRANTS=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT < $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql`
      IMPORT_USERGRANTS_STAT=`echo $?`

      if [ $IMPORT_USERGRANTS_STAT -eq 0 ]
      then
	echo "Successfully imported user's grants."
      else
	echo "Failed to import user's grants."
	exit
      fi
    else
      echo "Failed to create $USERNAME user."
      exit
    fi

  done

  rm -f $DB_DETAILS_DIR/$DB_INST_NAME-usergrants.sql
  rm -f $DB_DETAILS_DIR/$DB_INST_NAME-user.csv

  # Create repl_user in Source Database
  echo "Creating replica user in source database..."

  RANDOM_PASSWD=`< /dev/urandom tr -dc A-Z-a-z-0-9 | head -c10`

  CREATE_REPL_USER=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "CREATE USER 'repl_user'@'%' IDENTIFIED BY '$RANDOM_PASSWD';"`
  CREATE_REPL_USER_STAT=`echo $?`
  CREATE_REPL_USER_GRANT=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%' IDENTIFIED BY '$RANDOM_PASSWD';"`
  CREATE_REPL_USER_GRANT_STAT=`echo $?`

  if [ $CREATE_REPL_USER_STAT -eq 0 -a $CREATE_REPL_USER_GRANT_STAT -eq 0 ]
  then
    echo "Successfully created replica user in the source database."
  else
    echo "Failed to create replica user in the source database."
    exit
  fi

  # Setup and Start replication in Destination Encrypted Database
  echo "Setting up replication in encrypted database..."

  SETUP_ENCRYPT_REPLICATION=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "CALL mysql.rds_set_external_master('$SRC_DB_ENDPT','3306','repl_user','$RANDOM_PASSWD','$RELAY_MASTER_LOG_FILE',$EXEC_MASTER_LOG_POS,0);"`
  SETUP_ENCRYPT_REPLICATION_STAT=`echo $?`
  START_ENCRYPT_REPLICATION=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$ENCRYPTED_DB_ENDPT -e "CALL mysql.rds_start_replication;"`
  START_ENCRYPT_REPLICATION_STAT=`echo $?`

  if [ $SETUP_ENCRYPT_REPLICATION_STAT -eq 0 -a $START_ENCRYPT_REPLICATION_STAT -eq 0 ]
  then
    echo "Successfully setup and started replication in the encrypted database."
    sleep 5
  else
    echo "Failed to setup and start replication in the encrypted database."
    exit
  fi

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
    RENAME_SOURCE_DB_INSTANCE=`aws rds modify-db-instance --db-instance-identifier $DB_INST_NAME --new-db-instance-identifier $DB_INST_NAME-old --apply-immediately --region $REGION`
    RENAME_SOURCE_DB_INSTANCE_STAT=`echo $?`

    if [ $RENAME_SOURCE_DB_INSTANCE_STAT -eq 0 ]
    then
      echo "Currently renaming $DB_INST_NAME to $DB_INST_NAME-old."
    else
      echo "Failed to rename $DB_INST_NAME to $DB_INST_NAME-old."
      exit
    fi

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

        RENAME_ENCRYPTED_DB_INSTANCE=`aws rds modify-db-instance --db-instance-identifier $DB_INST_NAME-encrypted --new-db-instance-identifier $DB_INST_NAME --apply-immediately --region $REGION`
	RENAME_ENCRYPTED_DB_INSTANCE_STAT=`echo $?`

	if [ $RENAME_ENCRYPTED_DB_INSTANCE_STAT -eq 0 ]
	then
	  echo "Currently renaming $DB_INST_NAME-encrypted to $DB_INST_NAME."
	else
	  echo "Failed to rename $DB_INST_NAME-encrypted to $DB_INST_NAME."
	  exit
	fi

	# check if the new name took effect
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
            EXEC_STOP_ENCRYPT_REPLICATION=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "CALL mysql.rds_stop_replication;"`
	    EXEC_STOP_ENCRYPT_REPLICATION_STAT=`echo $?`
            EXEC_RESET_MASTER=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "CALL mysql.rds_reset_external_master;"`
	    EXEC_RESET_MASTER_STAT=`echo $?`

	    if [ $EXEC_STOP_ENCRYPT_REPLICATION_STAT -eq 0 -a $EXEC_RESET_MASTER_STAT -eq 0 ]
 	    then
	      echo "Successfully stopped replication and reset replication setup."
	    else
	      echo "Failed to stop replication and reset replication setup."
	      exit 0
	    fi

	    # Delete repl_user
	    echo "Deleting repl_user..."
  	    DELETE_REPL_USER=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$SRC_DB_ENDPT -e "DROP USER 'repl_user'@'%';"`
	    DELETE_REPL_USER_STAT=`echo $?`

	    if [ $DELETE_REPL_USER_STAT -eq 0 ]
	    then
	      echo "Successfully deleted the replica user."
	    else
	      echo "Failed to delete the replica user."
	      exit
	    fi

            echo "Done migrating your database to an encrypted one."
            echo "Please verify if your application can connect and be able to perform transactions to the encrypted database $DB_INST_NAME."
            echo "Once verified, kindly stop/delete the old instance $DB_INST_NAME-old."

            echo "For now, $DB_INST_NAME-replica will be deleted..."
            DELETE_DB_REPLICA=`aws rds delete-db-instance --db-instance-identifier $DB_INST_NAME-replica --skip-final-snapshot --region $REGION`
	    DELETE_DB_REPLICA_STAT=`echo $?`

	    if [ $DELETE_DB_REPLICA_STAT -eq 0 ]
	    then
	      echo "Successfully deleted $DB_INST_NAME-replica."
              echo "DONE."
	    else
	      echo "Failed to delete $DB_INST_NAME-replica."
	      exit
	    fi
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
