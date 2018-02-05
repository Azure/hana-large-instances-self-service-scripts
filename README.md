
# Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (for example, label, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

# Legal Notices

Microsoft and any contributors grant you a license to the Microsoft documentation and other content
in this repository under the [Creative Commons Attribution 4.0 International Public License](https://creativecommons.org/licenses/by/4.0/legalcode),
see the [LICENSE](LICENSE) file, and grant you a license to any code in the repository under the [MIT License](https://opensource.org/licenses/MIT), see the
[LICENSE-CODE](LICENSE-CODE) file.

Microsoft, Windows, Microsoft Azure and/or other Microsoft products and services referenced in the documentation
may be either trademarks or registered trademarks of Microsoft in the United States and/or other countries.
The licenses for this project do not grant you rights to use any Microsoft names, logos, or trademarks.
Microsoft's general trademark guidelines can be found at http://go.microsoft.com/fwlink/?LinkID=254653.

Privacy information can be found at https://privacy.microsoft.com/en-us/

Microsoft and any contributors reserve all others rights, whether under their respective copyrights, patents,
or trademarks, whether by implication, estoppel or otherwise.

# Scripts

## azure_hana_backup.pl

The Azure HANA backup script has been updated to accomodate MCOS scenarios where multiple SAP HANA instances are running on the same HANA Large Instances. Changes are:
1.	All HANA instances will be snapshot backed up together
2.	The HANA SID does not have to be specified anymore. They are now called as follows:

### Usage

```
HANA backup covering /hana/data and /hana/shared (includes/usr/sap)
./azure_hana_backup.pl hana <snapshot_prefix> <snapshot_frequency> <number of snapshots retained>

For /hana/logbackups snapshot
./azure_hana_backup.pl logs <snapshot_prefix> <snapshot_frequency> <number of snapshots retained>

For snapshot of the volume storing the boot LUN
./azure_hana_backup.pl boot <HANA Large Instance Type> <snapshot_prefix> <snapshot_frequency> <number of snapshots retained>

```

You need to specify the following parameters: 

- The first parameter characterizes the type of the snapshot backup. The values allowed are **hana**, **logs**, and **boot**. 
- The parameter **<HANA Large Instance Type>** is necessary for boot volume backups only. There are two valid values with "TypeI" or "TypeII" dependent on the HANA Large Instance Unit. To find out what "Type" your unit is, read this [documentation](https://docs.microsoft.com/azure/virtual-machines/workloads/sap/hana-overview-architecture).  
- The parameter **<snapshot_prefix>** is a snapshot or backup label for the type of snapshot. It has two purposes. The one purpose for you is to give it a name, so that you know what these snapshots are about. The second purpose is for the script azure\_hana\_backup.pl to determine the number of storage snapshots that are retained under that specific label. If you schedule two storage snapshot backups of the same type (like **hana**), with two different labels, and define that 30 snapshots should be kept for each, you are going to end up with 60 storage snapshots of the volumes affected. 
- The parameter **<snapshot_frequency>** is reserved for future developments and does not have any impact. We recommend setting it right now to "3min" when executing backups of the type log and "15min", when executing the other backup types
- The parameter **<number of snapshots retained>** defines the retention of the snapshots indirectly, by defining the number of snapshots of with the same snapshot prefix (label) to be kept. This parameter is important for a scheduled execution through cron. If the number of snapshots with the same snapshot_prefix would exceed the number given by this parameter, the oldest snapshot is going to be deleted before executing a new storage snapshot.

In the case of a scale-out, the script does some additional checking to ensure that you can access all the HANA servers. The script also checks that all HANA instances return the appropriate status of the instances before it creates an SAP HANA snapshot. The SAP HANA snapshot is followed by a storage snapshot.

## azure_hana_replication_status.pl

This script is design to provide basic details around the replication status from the Production site to the Disaster Recovery site.  The script is designed to assure customers that replication is taking place and the sizes of items that are being replicated.  It also provides guidance if a replication is taking too long or if the link is potentially down.

### Usage
This script is run from the disaster recovery location so an active server is required in the Disaster Recovery Site.
The script is executed by:

```
SAPTSTHDB100:/scripts # ./azure_hana_replication_status.pl
```

It uses the same HANABackupCustomerDetails.txt to obtain the necessary information to log in to the storage as appropriate.
Once executed, it prints all found relationships with HANA Instance HM3 as part of the volume name:

```
volume expected:hana_data_hm3_mnt00001_t020_dp
volume expected:hana_data_hm3_mnt00002_t020_dp
volume expected:hana_data_hm3_mnt00003_t020_dp
volume expected:hana_log_backups_hm3_t020_dp
volume expected:hana_shared_hm3_t020_dp
```

The customer is then able to match that with the results that follow. There are two main statuses a customer is interested in: Active and Broken-off. A relationship will show as broken-off if the replica is intentionally cut by Operations, (or the customer uses their credentials to gain access to the storage and did it to themselves), or the DR failover script has gone afoul.  Otherwise, status will be active. After that, the replication details will show a lag time. The lag time represents the amount of time that has passed since the previous replication started until the latest replication finishes. For example, if it has only been 45 minutes since the last data filesystem replication then the lag time will show as 45 minutes.  The lag-time will continue to increase until the hourly replication finishes. Therefore, there is note in the script that states any lag time up to 90 minutes is acceptable.  After that, either the replication link is not active or the customer is trying to replicate too much data a time.  The link will show current replication activity as idle unless it is actively replicating data.  Finally, sometimes a customer will see an actual snapshot listed that they created and sometimes the customer will see only the snapmirror relationship being updated.  Since we are not in control of when the snapshots are created, we cannot only replicate every hour as it is possible that we might miss the snapshot creation by a minute and we wait a full extra hour before replicating that snapshot whereas we caught the last one putting two hours between snapshot replication. Therefore, the snapmirror scheduled replica occurs more frequently than the expected snapshot.

Below are both an example of the replication link active and the replication as failed:

```
*************************************************
hana_shared_hm3_t020_dp
-------------------------------------------------
Link Status: Active
Current Replication Activity: Idle
Latest Snapshot Replicated: snapmirror.c169b434-75c0-11e6-9903-00a098a13ceb_2154095459.2017-06-23_061500
Size of Latest Snapshot Replicated: 8.71MB
Current Lag Time between snapshots: 0:42:33   ***Less than 90 minutes is acceptable***
```

```
*************************************************
hana_log_backups_hm3_t020_dp
-------------------------------------------------
Link Status: Broken-Off
Current Replication Activity: Idle
Latest Snapshot Replicated: snapmirror.c169b434-75c0-11e6-9903-00a098a13ceb_2154095460.2017-04-21_051516
Size of Latest Snapshot Replicated: 204KB
Current Lag Time between snapshots: -   ***Less than 20 minutes is acceptable***
```

## azure_hana_snapshot_delete.pl

This script is designed to delete a snapshot or set of snapshots by either using the HANA backupid as found in studio or by the snapshot name itself.  Currently, the backupid is only tied to the snapshots created for the data filesystems.  Otherwise, if the snapshot ID is entered it will seek all snapshots that match the entered snapshot.  

Note: currently the backup scripts do not seek to normalize the snapshot count so if a customer deletes snapshot .23 for whatever reason then the script will not seek to ensure continuity between the numbering so will always have a gap in the numbering.  This could cause problems as the backup script is based on an entered retention number that looks at the .XX number to determine if it should be removed.  A customer could accidentally delete only the 25th snapshot of retention 30 because some snapshots have been deleted.

### Usage

The customer enters ./azure_hana_snapshot_delete.pl as root.

The script provides a warning regarding that snapshot deletion is locked out until the snapshot is over an hour old to not cause problems with replication.

```
SAPTSTHDB100:/scripts # ./azure_hana_snapshot_delete.pl
This script is intended to delete either a single snapshot or all snapshots that pertain to a particular HANA storage snapshot by its HANA Backup ID
found in HANA Studio.  A snapshot cannot be deleted if it is less than an hour old as deletion can interfere with replication. Please enter whether you wish to delete by backupid or snapshot, and, if by snapshot, enter the volume name and snapshot name where the snapshot is found.  The azure_hana_snapshot_details script may be used to identify individual snapshot names and volume locations.

Do you want to delete by snapshot name or by HANA backup id?
Please enter (backupid/snapshot/quit):
```

The customer then selects whether they wish to delete by HANA Backup ID, Snapshot or Quit.  If they select backupid, it will ask for the HANA Backup ID they wish to delete.  This will search all volumes for the HANA Backup ID in the comments section. In the latest script, only the boot volumes and log backups will not have the common HANA Backup ID.

```
Do you want to delete by snapshot name or by HANA backup id?
Please enter (backupid/snapshot/quit): backupid
input: backupid
Please enter either the backup id of the HANA Storage Snapshot you wish to delete:
12356
```

Successful output is then shown as below where it identifies each snapshot by volume that is deleted that matches the corresponding HANA Backup ID.

```
**********************Seeking backup id in found Storage Snapshots**********************
Adding Snapshot hm2_1 from volume hana_data_test
Adding Snapshot hm2_2 from volume hana_data_test
Checking time stamp for snapshot hm2_1 of volume hana_data_test
Snapshot hm2_1 of volume hana_data_test was successfully deleted
Checking time stamp for snapshot hm2_2 of volume hana_data_test
Snapshot hm2_2 of volume hana_data_test was successfully deleted
Command completed successfully.
Exiting with return code: 0
```

If the customer selects snapshot, they have the capability of deleting each snapshot individually.  They will be asked first for the volume that contains the snapshot and then the actual snapshot name.  If the snapshot exists in that volume and is aged more than one hour, it will be deleted. The customer can find the volume names and snapshot names from the azure_hana_snapshot_details script. Finally, the customer is warned that if data only exists on this snapshot then execution means that data is lost forever.

```
Do you want to delete by snapshot name or by HANA backup id?
Please enter (backupid/snapshot/quit): snapshot
input: snapshot
Please enter either the volume location of the snapshot you wish to delete:
hana_data_test
Please enter either the snapshot you wish to delete:
hm3
You have requested to delete snapshot hm3 from volume hana_data_test. Any data that exists only on this snapshot is lost forever. Do you wish to proceed (yes/no)?
Please enter (yes/no):  yes
```

A successful deletion looks like the example below:

```
*********************Deleting Snapshot hm3 from Volume hana_data_test**********************
Snapshot hm3 of volume hana_data_test was successfully deleted
Command completed successfully.
Exiting with return code: 0
```

## azure_hana_snapshot_details.pl

The purpose of this document is to provide the customer a list of basic details about all the snapshots per volume that exist in the customer’s environment. This script can be run in either location if there is an active server in the Disaster Recovery Location.  The script provides the following broken down by each volume that contains snapshots: the size of total snapshots in a volume, and then each snapshot in that volume with the following details: the snapshot name, create time, size of snapshot, the frequency of the snapshot, and the HANA Backup ID associated with that snapshot (if relevant).

### Usage
The customer executes the script with the following command:

```
SAPTSTHDB100:/scripts # ./azure_hana_snapshot_details.pl
```

This script, like all others, requires HANABackupCustomerDetails.txt to be filled out.
The script displays a significant amount of data as it is being obtained and sorted.  Eventually, final output begins with output like below:

```
**********************************************************
****Volume: hana_shared_hm1_vol       ***********
**********************************************************
Total Snapshot Size:  260KB
----------------------------------------------------------
Snapshot:   snapshotTest
Create Time:   "Thu Feb 02 21:36:45 2017"
Size:   260KB
Frequency:   -
HANA Backup ID:   -
```

Each volume is shown like above with its associated total snapshot size. Then each snapshot is shown. This example only had a single snapshot. The next example has several snapshots but only the first several snapshots are shown:

```
**********************************************************
****Volume: hana_shared_SAPTSTHDB100_t020_vol       ***********
**********************************************************
Total Snapshot Size:  411.8MB
----------------------------------------------------------
Snapshot:   snap.2016-09-20_1404.0
Create Time:   "Tue Sep 20 18:08:35 2016"
Size:   2.10MB
Frequency:   freq 
HANA Backup ID:   
----------------------------------------------------------
Snapshot:   snap.2016-09-20_1532.0
Create Time:   "Tue Sep 20 19:36:21 2016"
Size:   2.37MB
Frequency:   freq
HANA Backup ID:   
```

Note: The frequency is what is put as frequency by the customer in the snapshot creation scripts.  It has been seen that customers already have come up with some pretty interesting names for frequency.

## removeTestStorageSnapshot.pl

This script is run to delete the temp snapshot that is created in each volume after running the Test Storage Connection Script. A snapshot must exist in each volume for a HANA instance before the backup scripts are run otherwise the backup scripts will have errors. Eventually, the errors will go away if you run the script the same number of times the total number of volumes that make up that HANA instance. It is much cleaner as part of the testing to create a temporary snapshot.  This script removes that temporary snapshot after each backup script is executed once successfully.

### Usage
The script is run as follows with the HANA instance to be test entered as an argument:

```
SAPTSTHDB100:/scripts # ./removeTestStorageSnapshot.pl
```

Like the test Storage Snapshot Connection script, the script will initiate a test login to the storage using the credentials provided in the HANABackupCustomerDetails.txt document. If successful, the following will be shown:

```
**********************Checking access to Storage**********************
Storage Access successful!!!!!!!!!!!!!!
```

Otherwise, the following is shown with some guidance as to how to potentially fix the problem:

```
**********************Checking access to Storage**********************
WARNING: Storage check status command 'volume show -type RW -fields volume' failed: 65280
WARNING: Please check the following:
WARNING: Was publickey sent to Microsoft Service Team?
WARNING: If passphrase entered while using tool, publickey must be re-created and passphrase must be left blank for both entries
WARNING: Ensure correct IP address was entered in HANABackupCustomerDetails.txt
WARNING: Ensure correct Storage backup name was entered in HANABackupCustomerDetails.txt
WARNING: Ensure that no modification in format HANABackupCustomerDetails.txt like additional lines, line numbers or spacing
WARNING: ******************Exiting Script*******************************
```

If the login is successful, the script obtains all volumes that belong to the provided HANA instance and delete the temporary snapshot previously created for each volume:

```
**********************Deleting existing testStorage snapshots**********************
Checking if snapshot testStorage.temp exists for hana_data_hm3_mnt00001_t020_dp on SVM 10.250.20.31  ...
hana_data_hm3_mnt00001_t020_dp found.
Snapshot testStorage.temp on hana_data_hm3_mnt00001_t020_dp not found.
Recent snapshot testStorage.recent does not exist on hana_data_hm3_mnt00001_t020_dp.
Checking if snapshot testStorage.temp exists for hana_data_hm3_mnt00001_t020_vol on SVM 10.250.20.31  ...
hana_data_hm3_mnt00001_t020_vol found.
Snapshot testStorage.temp on hana_data_hm3_mnt00001_t020_vol found.
Removing recent snapshot testStorage.recent on hana_data_hm3_mnt00001_t020_vol on SVM 10.250.20.31  ...
testStorage.2017-06-23_0239.temp
```

It is okay if the temp snapshot cannot be found and does not necessarily mean an error occurred.

## testStorageSnapshotConnection.pl

This script has two purposes. First, to ensure that the server used for scripts has access to the customer’s storage area before the customer runs the backup scripts. Second, to create a temp snapshot for the HANA instance the customer is testing.  This script should be run for every HANA instance on a server if multi-purpose to ensure that the backup scripts function as expected.

### Usage
The script is run as follows with the HANA instance to be test entered as an argument:

```
SAPTSTHDB100:/scripts # ./testStorageSnapshotConnection.pl
```

Next, the script initiates a test login to the storage using the credentials provided in the HANABackupCustomerDetails.txt document. If successful, the following is shown:

```
**********************Checking access to Storage**********************
Storage Access successful!!!!!!!!!!!!!!
```

Otherwise, the following is shown with some guidance as to how to potentially fix the problem:

```
**********************Checking access to Storage**********************
WARNING: Storage check status command 'volume show -type RW -fields volume' failed: 65280
WARNING: Please check the following:
WARNING: Was publickey sent to Microsoft Service Team?
WARNING: If passphrase entered while using tool, publickey must be re-created and passphrase must be left blank for both entries
WARNING: Ensure correct IP address was entered in HANABackupCustomerDetails.txt
WARNING: Ensure correct Storage backup name was entered in HANABackupCustomerDetails.txt
WARNING: Ensure that no modification in format HANABackupCustomerDetails.txt like additional lines, line numbers or spacing
WARNING: ******************Exiting Script*******************************
```

If the login is successful, the script obtains all volumes that belong to the provided HANA instance and create a snapshot for each volume:

```
**********************Creating Storage snapshot**********************
Taking snapshot testStorage.recent for hana_data_hm3_mnt00001_t020_dp ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_data_hm3_mnt00001_t020_vol ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_data_hm3_mnt00002_t020_dp ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_data_hm3_mnt00002_t020_vol ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_data_hm3_mnt00003_t020_dp ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_data_hm3_mnt00003_t020_vol ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_log_backups_hm3_t020_dp ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_log_backups_hm3_t020_vol ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_log_hm3_mnt00001_t020_vol ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_log_hm3_mnt00002_t020_vol ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_log_hm3_mnt00003_t020_vol ...
Snapshot created successfully.
Taking snapshot testStorage.recent for hana_shared_hm3_t020_vol ...
Snapshot created successfully.
```

## azure_hana_replication_status.pl

This script provides the basic details around the replication status from the production site to the disaster-recovery site. The script monitors to ensure that the replication is taking place, and it shows the size of the items that are being replicated. It also provides guidance if a replication is taking too long or if the link is down.