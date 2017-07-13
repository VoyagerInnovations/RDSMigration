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
2. [AWS CLI](https://aws.amazon.com/cli/) installed in the EC2 instance
3. MySQL client package

## Using the script
The quick brown fox

## Limitations
- This script only works for AWS MySQL RDS

## Post migration activities
1. Check the target DB data
2. Stop the old RDS instance
3. Check application user experience
4. Delete the old RDS instance 
