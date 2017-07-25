# RDSMigration
A fully automated RDS migration (to encrypted) script.

## What the script does
Create a usable copy of an existing MySQL RDS with encryption enabled (KMS).

In detail, the following are the operations that will be performed:
1. Perform flight check
2. Get information about the source RDS
3. Create a temporary read replica for the source RDS. This will be used to get a consistent copy of the source RDS
4. Create the KMS key for encrypting the target RDS
5. Create the target encrypted RDS
6. Stop replication between the source RDS and the temporary read replica
7. Dump and export the data from the temporary read replica to the target RDS
8. Copy RDS tags from the source RDS to the target RDS
9. Copy application users from the temporary read replica to the target RDS
10. Create replication user in the source RDS
11. Let the target RDS catch up with the source RDS
12. Rename the source RDS to a temporary name
13. Rename the target RDS to the original name of the source RDS (so app doesn't need to be changed)
14. Stop replication between the source RDS and target RDS
15. Delete the temporary source RDS read replica


## Diagram
![RDSMigrate Diagram](https://raw.githubusercontent.com/VoyagerInnovations/RDSMigration/master/images/rdsmigrate.png)

## Pre-requisites
You need the following to run the script.

1. An EC2 instance. This instance must be able to connect to both the source and target RDS

    a. IAM Role. Create an IAM role for the EC2 instance with the following inline policies and permissions.
 
    Role Name: EC2RoleDBReplication
    
    Role Inline Policy Name: 
    ```
     AccessToKMS
     AccessToRDS
     AccessToIAM
     ```
    
    1. AccessToKMS
    ```
    {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1498031627000",
            "Effect": "Allow",
            "Action": [
                "kms:ListAliases",
                "kms:ListKeys",
                "kms:CreateKey",
                "kms:CreateAlias",
                "kms:Describe*"
            ],
            "Resource": [
                "*"
            ]
        }
     ]
   }
   ```
    2. AccessToRDS 
    ```
    {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1498038607000",
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBClusters",
                "rds:DescribeDBInstances"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Sid": "Stmt1498038692000",
            "Effect": "Allow",
            "Action": [
                "rds:CreateDBInstanceReadReplica",
                "rds:Describe*",
                "rds:CreateDBInstance",
                "rds:ModifyDBInstance",
                "rds:DeleteDBInstance",
                "rds:AddTagsToResource",
                "rds:ListTagsForResource"
            ],
            "Resource": [
                "*"
            ]
        }
      ]
    }
    ```
    3. AccessToIAM
    ```
    {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1499865345000",
            "Effect": "Allow",
            "Action": [
                "iam:ListPolicies",
                "iam:ListRoles",
                "iam:ListRolePolicies",
                "iam:GetRolePolicy"
            ],
            "Resource": [
                "*"
            ]
        }
      ]
    }
    ```


    b. Security Group. Modify the security group of the source and target RDS instance to allow port 3306 from the EC2 replication instance. Also, make sure that the target RDS can connect to port 3306 of the source RDS.

    c. [Launch instance](http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/launching-instance.html). In creating an instance for replication, attach the IAM role and security group created.
    
    
2. [AWS CLI](https://aws.amazon.com/cli/) installed in the EC2 instance
3. MySQL client package
```
    sudo yum install -y mysql
```
4. pv tool which monitor the progress of data through a pipe
```
    sudo yum install -y pv
```

## Using the script
1. Clone (or download) the repository
```
cd /home/ec2-user/
git clone https://github.com/VoyagerInnovations/RDSMigration.git
```

2. Run the script
```
Usage: ./migrate_database.sh [-i <iam_user_name>] [-n <db_instance_identifier>] [-u <db_admin_user>] [-p <db_admin_passwd>] [-m <yes/no> ] [-d <db_name>] [-a <account_number>] [-z <region_name>]

Options:
  -i <iam_user_name>            = IAM user who will administer the KMS key to be used in encrypting the database
  -n <db_instance_identifier>   = (Source) RDS Instance Identifier
  -u <db_admin_user>            = (Source) RDS DB Admin User
  -p <db_admin_passwd>          = (Source) RDS DB Admin Password
  -m <yes/no>                   = Indicate if the RDS instance contains multiple databases
  -d <db_name>                  = Specify the database name. This option can be excluded/skipped if the value of '-m' is yes
  -a <account_number>           = Specify the AWS account number where the resources resides
  -z <region_name>              = Specify the AWS Region where the resources resides
```

Example:

1. For RDS with single database:
```bash
./migrate_database.sh -i test_user -n TestDB -u admin -p admin1234 -m no -d testdb -a 123456789012 -z ap-southeast-1
```
2. For RDS with multiple databases:
```bash
./migrate_database.sh -i test_user -n TestDB -u admin -p admin1234 -m yes -a 123456789012 -z ap-southeast-1
```

## Limitations
- This script only works for AWS MySQL RDS

## Post migration activities
1. Check the target DB data
2. Stop the old RDS instance
3. Check application user experience
4. Delete the old RDS instance
5. Terminate the EC2 migration instance (if no longer necessary)
6. For RDS instances with existing read replica before migration, re-create the read replica to be able to catch up to the master.
