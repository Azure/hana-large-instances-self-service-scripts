#!/usr/bin/perl -w
#
# 
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
# 
# Specifications subject to change without notice.
#
# Name: azure_hana_backup.pl
#Version: 2.1
#Date 9/27/2017

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Time::HiRes;
#Usage:  This script is used to allow Azure HANA customers to create on-demand backups of their various HANA volumes.  The variable $numkeep describes the number of backup related snapshots that are created within
#		protected volumes. The backup is created through the snapshot process within NetApp.  This snapshot is created by calling the customer's Storage Virtual Machine and executing a snapshot.  The snapshot is given
#		a snapmirror-label of customer. The snapshot is then replicated to a backup folder using SnapVault.  SnapVault will have its own retention schedule that is kept independent of this script.
#
# Steps to configure the cluster:
#
# 1) Create a role with the following commands -- change vserver and role name to fit preferences:
#    security login role create -role hanabackup -cmddirname "volume snapshot rename" -vserver $strSVM
#    security login role create -role hanabackup -cmddirname "volume snapshot create" -vserver $strSVM
#    security login role create -role hanabackup -cmddirname "volume snapshot show" -vserver $strSVM ---> maybe duplicate
#    security login role create -role hanabackup -cmddirname "volume snapshot delete" -vserver $strSVM
#    security login role create -role hanabackup -cmddirname "volume snapshot list" -vserver $strSVM   ---> deprecated?
#    security login role create -role hanabackup -cmddirname "volume snapshot modify" -vserver $strSVM
#    security login role create -role hanabackup -cmddirname "volume show" -vserver $strSVM
#    security login role create -role hanabackup -cmddirname "set" -vserver $strSVM
# 2) Create a new user with the role and specifying ssh and publickey access:
#    security login create -user-or-group-name $strUser -role hanabackup -authmethod publickey -application ssh -vserver $strSVM
# 3) Create a new public key based on 'ssh-keygen' output (id_rsa.pub):
#    security login publickey create -username $strUser -vserver $strSVM -publickey "ssh-rsa AAAA<rest of key>"
#
#


#
# Global Tunables
#
# $numKeep            - The number of snapshots to keep
# $sshCmd             - The default SSH command to use
# $verbose            - Whether to be more verbose (or not)
# $strSVM             - The SVM (tenant) hosting the SAP HANA environment, by IP address
# $strUser            - The username to log into the SVM(s) with
# $strSnapshotPrefix  - The prefix name of the snapshot (number appended). i.e. Customer, Hourly, etc.
# $strHANACreateCmd   - The command to run to create the HANA snapshot
# $strHANADeleteCmd   - The command to run to delete the HANA snapshot
# $strHANAAdmin 			- The username on the HANA instance created with HANA backup credentials, typically SCADMINXX where XX is HANA instance number.
# $strHDBSQLPath			- Customer path to where application hdbsql exists
# $strHANAInstance 		- The HANA instance that requires snapshots to be created.  It looks for matching patterns in the volumes of the SVM that are RW
my $version = "2.1";
my @arrOutputLines;
my @fileLines;
my @strSnapSplit;
my @customerDetails;
my $strHANABackupID;
my $strExternalBackupID;
my $filename = "HANABackupCustomerDetails.txt";
#open the customer-based text file to gather required details
open(my $fh, '<:encoding(UTF-8)', $filename)
  or die "Could not open file '$filename' $!";

chomp (@fileLines=<$fh>);
close $fh;


#get Microsoft Services Team Provided Variables
@strSnapSplit = split(/: /, $fileLines[1]);
my $strUser = $strSnapSplit[1];
@strSnapSplit = split(/: /, $fileLines[2]);
my $strSVM = $strSnapSplit[1];
#get customer provided VARIABLES
@strSnapSplit = split(/: /, $fileLines[6]);
my $strHANANodeIP = $strSnapSplit[1];
@strSnapSplit = split(/: /, $fileLines[7]);
my $strHANANumInstance = $strSnapSplit[1];
@strSnapSplit = split(/: /, $fileLines[8]);
my $strHANAAdmin = $strSnapSplit[1];



#DO NOT MODIFY THESE VARIABLES!!!!
my $numKeep = $ARGV[3];
my $sshCmd = '/usr/bin/ssh';
my $verbose = 1;
my $strBackupType = $ARGV[0];
my $strHANAInstance = $ARGV[1];
my $strHANASID = uc $strHANAInstance;
my $strSnapshotPrefix = $ARGV[2];
my $hanaSnapshotSuccess = qq('Storage snapshot successful');
my $strHANAStatusCmdV1 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "\s"';
my $strHANAStatusCmdV2 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "\s"';
my $strHANACreateCmdV1 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data create snapshot"';
my $strHANACreateCmdV2 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "backup data for full system create snapshot"';
#my $strHANACreateCmd = "";
#my $strHANADeleteCmd = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data drop snapshot"';
my $strHANAIDRequestString = "select BACKUP_ID from M_BACKUP_CATALOG where ENTRY_TYPE_NAME = 'data snapshot' and STATE_NAME = 'prepared'";
my $strHANABackupIDRequestV1 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin .' "'. $strHANAIDRequestString.'"' ;
my $strHANABackupIDRequestV2 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -d SYSTEMDB -U ' . $strHANAAdmin .' "'. $strHANAIDRequestString.'"' ;

my $strHANACloseCmdSuccess;
my $strHANACloseCmdV1;
my $strHANACloseCmdV2;
my $strHANAVersion;

#my $strHANACloseCmdNoSuccess = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data close snapshot backup_id '.$strHANABackupID . ' UNSUCCESSFUL "DO NOT USE - Storage Snapshot Unsuccessful!" "'   ;
#my $strHANADeleteCmd = "";

my $arrSnapshot = "";
my $outputFilename = "";

# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE=0;
my $ERR_WARN=1;

# Log levels -- LOG_INFO, LOG_WARN.  Bitmap values
my $LOG_INFO=1;
my $LOG_WARN=2;

# Global parameters
my @snapshotLocations;
my @volLocations;
my $exitWarn = 0;
my $exitCode;


#
# Name: logMsg()
# Func: Print out a log message based on the configuration.  The
#       way messages are printed are based on the type of verbosity,
#       debugging, etc.
#


sub logMsg
{
	# grab the error string
	my ( $errValue, $msgString ) = @_;

	my $str;
	if ( $errValue & $LOG_INFO ) {
		$str .= "$msgString";
		$str .= "\n";
		if ( $verbose != 0 ) {
			print $str;
		}
	push (@arrOutputLines, $str);
	}

	if ( $errValue & $LOG_WARN ) {
		$str .= "WARNING: $msgString\n";
		$exitWarn = 1;
		print $str;
	}
}


#
# Name: runExit()
# Func: Exit the script, but be sure to print a report if one is
#       requested.
#
sub runExit
{
	$exitCode = shift;
	if ( ( $exitWarn != 0 ) && ( !$exitCode ) ) {
		$exitCode = $ERR_WARN;
	}

	# print the error code message (if verbose is selected)
	if ( $verbose != 0 ) {
		logMsg( $LOG_INFO, "Exiting with return code: $exitCode" );
	}

	# exit with our error code
	exit( $exitCode );
}


#
# Name: runShellCmd
# Func: Run a command in the shell and return the results.
#
sub runShellCmd
{
	#logMsg($LOG_INFO,"inside runShellCmd");
	my ( $strShellCmd ) = @_;
	return( `$strShellCmd 2>&1` );
}


#
# Name: runSSHCmd
# Func: Run an SSH command.
#
sub runSSHCmd
{
	#logMsg($LOG_INFO,"inside runSSHCmd");
	my ( $strShellCmd ) = @_;
	return(  `"$sshCmd" -l $strUser $strSVM 'set -showseparator ","; $strShellCmd' 2>&1` );
}


#
# Name: runCheckHANAVersion()
# Func: Checks version of HANA to determine which type of hdbsql commands to use
#
sub runCheckHANAVersion
{

  opendir my $handle,  '/hana/shared/'.$strHANASID.'/exe/linuxx86_64/';
  foreach (readdir $handle) {

      if ($_ =~ m/HDB/) {
        my @chars = split("", $_);
        $strHANAVersion = $chars[4];
      }
  }
  closedir $handle;

}

sub runCheckHANAStatus
{
			logMsg($LOG_INFO, "**********************Checking HANA status**********************");
			# Create a HANA database username via HDBuserstore
      if ($strHANAVersion eq 1) {
        my @out = runShellCmd( $strHANAStatusCmdV1 );
        logMsg($LOG_INFO, $strHANAStatusCmdV1);
      }
      if ($strHANAVersion eq 2) {
        my @out = runShellCmd( $strHANAStatusCmdV2 );
        logMsg($LOG_INFO, $strHANAStatusCmdV2);
      }
      if ( $? ne 0 ) {
          if ($strHANAVersion eq 1) {
              logMsg( $LOG_WARN, "HANA check status command '" . $strHANAStatusCmdV1 . "' failed: $?" );
          }
          if ($strHANAVersion eq 2) {
              logMsg( $LOG_WARN, "HANA check status command '" . $strHANAStatusCmdV2 . "' failed: $?" );
          }
          logMsg( $LOG_WARN, "Please check the following:");
          logMsg( $LOG_WARN, "hdbuserstore user command was executed with root");
          logMsg( $LOG_WARN, "Backup user account created in HANA Studio was made under SYSTEM");
          logMsg( $LOG_WARN, "Backup user account and hdbuserstore user account are case-sensitive");
          logMsg( $LOG_WARN, "The correct host name and port number are used");
          logMsg( $LOG_WARN, "Please check port number stored in hdbuserstore. HANA 1.0 should have port 3XX15 added while HANA 2.0 should have port 3XX13 where XX stands for the HANA Instance number.  ");
					logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
					exit;
				} else {
					logMsg( $LOG_INFO, "HANA status check successful." );
			}

}

sub runSetupVLIBackup() {

#  if (-e '/osbackups') {
#    logMsg($LOG_INFO,"/osbackups directory found");
#    system("mount -o bind / /RootClone");
#    system("mount -o bind /boot/efi /RootClone/boot/efi");

#    if (-e '/RootClone') {
#      system("rsync -aAHSv --numeric-ids --delete --exclude-from=/tmp/skiplist /RootClone/ /hana/backups/os/");
#    }

#    system("umount /RootClone/data1");
#    system("umount /RootClone/boot/efi");
#    system("umount /RootClone");




 #else {

# logMsg($LOG_WARN, "/osbackups directory not found. Exiting.");
   exit;
 #}

#  }
}
#
# Name: runGetVolumeLocations()
# Func: Get the set of production volumes that match specified HANA instance.
#
sub runGetVolumeLocations
{
  my $strSSHCmd;
  if ($strBackupType eq "hana") {
     logMsg($LOG_INFO, "**********************Getting list of volumes that match HANA instance specified**********************");
	   logMsg( $LOG_INFO, "Collecting set of volumes hosting HANA matching pattern *$strHANAInstance* ..." );
	   $strSSHCmd = "volume show -volume *".$strHANAInstance."* -volume !*log_backups* -volume !*log* -type RW -fields volume";
  }
  if ($strBackupType eq "boot") {
     logMsg($LOG_INFO, "**********************Getting list of volumes of boot volumes**********************");
     $strSSHCmd = "volume show -volume *boot* -type RW -fields volume";
  }
  if ($strBackupType eq "logs") {
    logMsg($LOG_INFO, "**********************Getting list of volumes that match HANA instance specified**********************");
	  logMsg( $LOG_INFO, "Collecting set of volumes hosting HANA matching pattern *$strHANAInstance* ..." );
	  $strSSHCmd = "volume show -volume *log_backups_".$strHANAInstance."* -type RW -fields volume";
  }

  my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
	} else {
		logMsg( $LOG_INFO, "Volume show completed successfully." );
	}
	my $i=0;
	my $listnum = 0;
	my $count = $#out - 1;
	for my $j (0 ... $count ) {
		$listnum++;
		next if ( $listnum <= 3 );
		chop $out[$j];
		my @arr = split( /,/, $out[$j] );

			my $name = $arr[$#arr-1];
			#logMsg( $LOG_INFO, $i."-".$name );
			if (defined $name) {
				logMsg( $LOG_INFO, "Adding volume $name to the snapshot list." );
				push( @volLocations, $name );

			}
	$i++;
	}
}


#
# Name: runCheckIfSnapshotExists
# Func: Verify if a snapshot exists.  Return 0 if it does not, 1 if it does.
#
sub runCheckIfSnapshotExists
{
	my $volName = shift;
	my $snapName = shift;
	my $tempSnapName = "";
	logMsg( $LOG_INFO, "Checking if snapshot $snapName exists for $volName on SVM $strSVM ..." );
	my @strSnapSplit;
	my $listnum = 0;
	#checking to make sure volume in $volName exists in the array
	for my $i (0 .. $#snapshotLocations) {
		if ($volName eq $snapshotLocations[$i][0]){
			logMsg( $LOG_INFO, "$volName found." );
			#with the volume found, each snapshot associated with that volume is now examxined
			my $aref = $snapshotLocations[$i];
			for my $j (0 .. $#{$aref} ) {
				@strSnapSplit = split(/\./, $snapshotLocations[$i][$j]);
				if (defined $strSnapSplit[2]) {
						$tempSnapName = $strSnapSplit[0].".".$strSnapSplit[2];
				} else {
						$tempSnapName = "";
				}
				if ( $tempSnapName eq $snapName ) {
					logMsg( $LOG_INFO, "Snapshot $snapName on $volName found." );
					return($snapshotLocations[$i][$j]);
				}
			}
		}
	}
	logMsg( $LOG_INFO, "Snapshot $snapName on $volName not found." );
	return( "0" );

}


#
# Name: runRotateSnapshots()
# Func: Rotate the snapshots in a loop
#
sub runRotateSnapshots
{
logMsg($LOG_INFO, "**********************Rotating snapshot numbering to allow new snapshot**********************");
my $rotateIndex;
my $checkSnapshotResult = "";
	# let's go through all the Filer and volume paths, rotating snapshots for each
for my $i (0 .. $#snapshotLocations) {
		# set up our loop counters
    my $aref = $snapshotLocations[$i];
    my $arraySize = $#{$aref} +1 ;


    if ($arraySize <= $numKeep) {
        $rotateIndex = $arraySize;
    } else {
        $rotateIndex = $numKeep;
    }
    my $j = $rotateIndex;
		my $k = $rotateIndex - 1;
		# get the SVM and volume name(s)
		my $volName = $snapshotLocations[$i][0];
		my $checkSnapshotResult;
		# iterate through all the snapshots
		logMsg( $LOG_INFO, "Rotating snapshots named $strSnapshotPrefix.# on $snapshotLocations[$i][0] ..." );

		while ( $k >= 0 ) {

			$checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0], "$strSnapshotPrefix\.$k" );

			if ( $checkSnapshotResult ne "0") {
        Time::HiRes::sleep (0.5+rand(0.5));
				my @strSnapSplit = split(/\./, $checkSnapshotResult);
				my $strSSHCmd = "volume snapshot rename -volume $snapshotLocations[$i][0] -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.$k -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.$j";
				my @out = runSSHCmd( $strSSHCmd );
				if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
				}
			}
			$j--; $k--;
		}
	}
}


#
# Name: runRemoveOldestSnapshot()
# Func: Remove the oldest snapshot once we're ready to clean up.
#This routine checks to see if there is a snapshot equal to the variable $numKeep which keeps track of the maximimun number of snapshots that will exist in the production volume.  This
# value is indepedent of any retention policies set in SnapVault.
sub runRemoveOldestSnapshot
{
	my $iteration = shift;
	logMsg($LOG_INFO, "**********************Deleting oldest snapshot list**********************");
	if ($iteration eq "1") {
			logMsg($LOG_INFO, "**********************Failure removing oldest snapshot acceptable**********************");
	}
	if ($iteration eq "2") {
			logMsg($LOG_INFO, "**********************Failure removing oldest snapshot unacceptable**********************");
	}
	for my $i (0 .. $#snapshotLocations) {
		# let's make sure the snapshot is there first
		my $checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0], $strSnapshotPrefix . "." . $numKeep );
		if ( $checkSnapshotResult eq "0" ) {
			logMsg( $LOG_INFO, "Oldest snapshot " . $strSnapshotPrefix . "." . $numKeep . " does not exist on $snapshotLocations[$i][0]." );
		} else {
			logMsg( $LOG_INFO, "Removing oldest snapshot $strSnapshotPrefix\.$numKeep on $snapshotLocations[$i][0] on SVM $strSVM ..." );

			my $strSSHCmd = "volume snapshot delete -volume $snapshotLocations[$i][0] -snapshot $checkSnapshotResult";
			my @out = runSSHCmd( $strSSHCmd );
			if ( $? ne 0 ) {
				logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
			}
		}
	}
}


#
# Name: runRemoveRecentSnapshot()
# Func: Remove the recent snapshot once we're ready to clean up.
#
sub runRemoveRecentSnapshot
{
logMsg($LOG_INFO, "**********************Deleting existing *.recent snapshot**********************");
logMsg($LOG_INFO, "**********************Failures are allowed if *.recent was properly cleaned up last backup**********************");
	for my $i (0 .. $#snapshotLocations) {
		# let's make sure the snapshot is there first
		my $checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0], "$strSnapshotPrefix\.recent");
		if ($checkSnapshotResult eq "0") {
			logMsg( $LOG_INFO, "Recent snapshot $strSnapshotPrefix\.recent does not exist on $snapshotLocations[$i][0]." );
		} else {
			# delete the recent snapshot
			logMsg( $LOG_INFO, "Removing recent snapshot $strSnapshotPrefix\.recent on $snapshotLocations[$i][0] on SVM $strSVM ..." );
			logMsg($LOG_INFO, $checkSnapshotResult);
			my $strSSHCmd = "volume snapshot delete -volume $snapshotLocations[$i][0] -snapshot $checkSnapshotResult";

			my @out = runSSHCmd( $strSSHCmd );
			if ( $? ne 0 ) {
				logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
			}
		}
	}
}


#
# Name: runRenameRecentSnapshot()
# Func: Take a NetApp snapshot utilizing the snapshot name.
#After the snapshot is created as snapshot.recent, it must be renamed to match numbering scheme of snapshots
sub runRenameRecentSnapshot
{
	logMsg($LOG_INFO, "**********************Renaming *.recent snapshot to *.0**********************");
	for my $i (0 .. $#snapshotLocations) {
		logMsg( $LOG_INFO, "Renaming snapshot $strSnapshotPrefix\.recent to $strSnapshotPrefix\.0 for $snapshotLocations[$i][0] on SVM $strSVM ..." );
		my $checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0], "$strSnapshotPrefix\.recent");
		if ($checkSnapshotResult eq "0") {
			logMsg( $LOG_INFO, "Recent snapshot $strSnapshotPrefix\.recent does not exist on $snapshotLocations[$i][0]." );
		} else {
				my @strSnapSplit = split(/\./, $checkSnapshotResult);
				#logMsg($LOG_INFO,$checkSnapshotResult);
				my $strSSHCmd = "volume snapshot rename -volume $snapshotLocations[$i][0] -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.recent -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.0";
				my @out = runSSHCmd( $strSSHCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
				} else {
						logMsg( $LOG_INFO, "Snapshot rename completed successfully." );
				}
		}
	}
}


#
# Name: runCreateHANASnapshot()
# Func: Create the HANA snapshot
#
sub runCreateHANASnapshot
{
	if ($strBackupType eq "hana") {

      my $strHANACreateCmd;
			logMsg($LOG_INFO, "**********************Creating HANA snapshot**********************");
			# Create a HANA database snapshot via HDBuserstore, key snapper
      if ($strHANAVersion eq 1) {
        $strHANACreateCmd = $strHANACreateCmdV1;
      }
      if ($strHANAVersion eq 2) {
        $strHANACreateCmd = $strHANACreateCmdV2;
      }
      logMsg( $LOG_INFO, "Creating the HANA snapshot with command: \"$strHANACreateCmd\" ..." );
			my @out = runShellCmd( $strHANACreateCmd );
			if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "HANA snapshot creation command '" . $strHANACreateCmd . "' failed: $?" );
					logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
					exit;
				} else {
					logMsg( $LOG_INFO, "HANA snapshot created successfully." );
			}
	}
}

#
#Name: runCheckHANASnapshotStatus
#Func: Verifies that HANA snapshot occured and obtains ID
#
sub runCheckHANASnapshotStatus
{

  my @out;
  if ($strBackupType eq "hana") {
      my $strRequest;
      logMsg($LOG_INFO, "**********************Checking for HANA snapshot and obtaining ID**********************");
      # Create a HANA database snapshot via HDBuserstore, key snapper
      if ($strHANAVersion eq 1) {
        logMsg( $LOG_INFO, "Checking HANA snapshot status with command: \"$strHANABackupIDRequestV1\" ..." );
        @out = runShellCmd( $strHANABackupIDRequestV1 );
        $strRequest = $strHANABackupIDRequestV1;
      }
      if ($strHANAVersion eq 2) {
        logMsg( $LOG_INFO, "Checking HANA snapshot status with command: \"$strHANABackupIDRequestV2\" ..." );
        @out = runShellCmd( $strHANABackupIDRequestV2 );
        $strRequest = $strHANABackupIDRequestV2;
      }
      logMsg( $LOG_INFO, 'row 1'.$out[1] );
      $strHANABackupID = $out[1];
#      my @strBackupSplit = split(/^/, $strHANABackupID);
#      logMsg( $LOG_INFO, 'row 0:'.$strBackupSplit[0] );
#      logMsg( $LOG_INFO, 'row 1:'.$strBackupSplit[1] );
      $strHANABackupID =~ s/\r|\n//g;
      logMsg( $LOG_INFO, 'hanabackup id: '.$strHANABackupID);
      if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "HANA snapshot creation command '" . $strRequest . "' failed: $?" );
          logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
          exit;
        } else {
          logMsg( $LOG_INFO, "HANA snapshot created successfully." );
      }
  }

}


sub runHANACloseSnapshot
{
  if ($strBackupType eq "hana") {
      my $strHANACloseCmd;
      logMsg($LOG_INFO, "**********************Closing HANA snapshot**********************");
      # Delete the HANA database snapshot
      if ($strHANAVersion eq 1) {
        $strHANACloseCmdV1 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data close snapshot backup_id '. $strHANABackupID . ' SUCCESSFUL '.$hanaSnapshotSuccess.qq(");
        $strHANACloseCmd = $strHANACloseCmdV1;
      }
      if ($strHANAVersion eq 2) {
        $strHANACloseCmdV2 = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -d SYSTEMDB -U ' . $strHANAAdmin . ' "backup data for full system close snapshot backup_id '. $strHANABackupID . ' SUCCESSFUL '.$hanaSnapshotSuccess.qq(");
        $strHANACloseCmd = $strHANACloseCmdV2;
      }
      logMsg( $LOG_INFO, "Deleting the HANA snapshot with command: \"$strHANACloseCmd\" ..." );
      my @out = runShellCmd( $strHANACloseCmd );
      if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "HANA snapshot deletion command '" . $strHANACloseCmd . "' failed: $?" );
      } else {
          logMsg( $LOG_INFO, "HANA snapshot closed successfully." );
      }
  }

}


#
#Storage snapshot functions
#
#
# Name: runCreateStorageSnapshot()
# Func: Take a NetApp snapshot utilizing the snapshot name.
#
sub runCreateStorageSnapshot
{
logMsg($LOG_INFO, "**********************Creating Storage snapshot**********************");
    my $strSSHCmd;
    for my $i (0 .. $#snapshotLocations) {
		# take the recent snapshot with SSH
		logMsg( $LOG_INFO, "Taking snapshot $strSnapshotPrefix\.recent for $snapshotLocations[$i][0] ..." );
#storage command necessary to create storage snapshot, others items to include: snapmirror-label matching snapshot type/frequency and HANA snapshot backup id matching as comment
		my $date = localtime->strftime('%Y-%m-%d_%H%M');
    if ($strBackupType eq "hana") {
      $strSSHCmd = "volume snapshot create -volume $snapshotLocations[$i][0] -snapshot $strSnapshotPrefix\.$date\.recent -snapmirror-label $strSnapshotPrefix -comment $strHANABackupID" ;
    }
    if ($strBackupType eq "li" or $strBackupType eq "logs" or $strBackupType eq "vli") {
      $strSSHCmd = "volume snapshot create -volume $snapshotLocations[$i][0] -snapshot $strSnapshotPrefix\.$date\.recent -snapmirror-label $strSnapshotPrefix" ;
    }
    my @out = runSSHCmd( $strSSHCmd );
		if ( $? ne 0 ) {
			logMsg( $LOG_WARN, "Snapshot creation command '" . $strSSHCmd . "' failed: $?" );
		} else {
			logMsg( $LOG_INFO, "Snapshot created successfully." );
		}
	}
}



sub runGetSnapshotsByVolume
{
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
		my $i = 0;

		logMsg( $LOG_INFO, "Collecting set of snapshots for each volume hosting HANA matching pattern *$strHANAInstance* ..." );
		foreach my $volName ( @volLocations ) {
				my $j = 0;
				$snapshotLocations[$i][$j] = $volName;
				my $strSSHCmd = "volume snapshot show -volume $volName -fields snapshot";
				my @out = runSSHCmd( $strSSHCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
						return( 0 );
				}
				my $listnum = 0;
				$j=1;
				my $count = $#out-1;
				foreach my $k ( 0 ... $count ) {
							#logMsg($LOG_INFO, $item)
							$j++;
							$listnum++;
							if ( $listnum <= 4) {
								chop $out[$k];
								$j=1;
							}
							my @strSubArr = split( /,/, $out[$k] );
							my $strSub = $strSubArr[$#strSubArr-1];
							$snapshotLocations[$i][$j] = $strSub;
				}
				$i++;
		}

}

sub runClearSnapshotLocations
{
  logMsg($LOG_INFO, "**********************Clearing snapshot list**********************");
  undef @snapshotLocations;
}

sub displayArray
{
logMsg($LOG_INFO, "**********************Displaying Snapshots by Volume**********************");
         for my $i (0 .. $#snapshotLocations) {
                my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref} ) {

                         logMsg($LOG_INFO,$snapshotLocations[$i][$j]);
                 }
         }

}


sub runRemoveOlderSnapshots
{
	#check to see if

	logMsg($LOG_INFO, "**********************Rotating snapshot numbering to allow new snapshot**********************");
	my $checkSnapshotResult = "";
		# let's go through all the Filer and volume paths, rotating snapshots for each
	for my $i (0 .. $#snapshotLocations) {
			# set up our loop counters
			my $j = $#{$snapshotLocations[$i]};
			# get the SVM and volume name(s)
			my $volName = $snapshotLocations[$i][0];
			my $checkSnapshotResult;
			# iterate through all the snapshots
			logMsg( $LOG_INFO, "Rotating older snapshots named $strSnapshotPrefix.$j on $snapshotLocations[$i][0] ..." );

			while ( $j >= $numKeep ) {

				$checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0], "$strSnapshotPrefix\.$j" );

				if ( $checkSnapshotResult ne "0") {

					my @strSnapSplit = split(/\./, $checkSnapshotResult);
					if ($strSnapSplit[1] ne ""){
            my $checkSnapshotAge = runCheckSnapshotAge($strSnapSplit[1]);
					       if ($checkSnapshotAge) {
							        my $strSSHCmd = "volume snapshot delete -volume $snapshotLocations[$i][0] -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.$j";
							        my @out = runSSHCmd( $strSSHCmd );
							        if ( $? ne 0 ) {
								          logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
							        }
					        } else {
								      logMsg( $LOG_INFO, "snapshot aged less than one hour... cannot delete. Stopping execution." );
								      die;
					        }
				    }
        }
				$j--;
			}
		}
    #if $numkeep equals zero then the script assumes
    if ($numKeep eq '0') {
      exit;
    }
}


sub runCheckSnapshotAge
{

  my $snapshotTimeStamp = shift;
	logMsg($LOG_INFO, $snapshotTimeStamp);
	my $t = Time::Piece->strptime($snapshotTimeStamp, '%Y-%m-%d_%H%M');
  logMsg($LOG_INFO,$t);
	my $tNum = str2time($t);

	my $currentTime = localtime->strftime('%Y-%m-%d_%H%M');
	my $currentT = Time::Piece->strptime($currentTime,'%Y-%m-%d_%H%M');

	my $currentTNum = str2time($currentT);
	logMsg($LOG_INFO,$tNum);
	logMsg($LOG_INFO,$currentTNum);

if ((str2time($currentT)-str2time($t))>3600) {
			return 1;
	} else {
			return 0;
	}
}

sub runPrintFile
{
	my $myLine;
	my $date = localtime->strftime('%Y-%m-%d_%H%M');
	$outputFilename = "$strSnapshotPrefix.$date.txt";
	my $existingdir = './snapshotLogs';
	mkdir $existingdir unless -d $existingdir; # Check if dir exists. If not create it.
	open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
	foreach $myLine (@arrOutputLines) {
		print $fileHandle $myLine;


	}
	close $fileHandle;
}

##### --------------------- MAIN CODE --------------------- #####
logMsg($LOG_INFO,"Executing Azure HANA Backup, Version $version");

if ($strSnapshotPrefix eq "" or $numKeep eq "" or $strHANAInstance eq "" and $strBackupType ne "boot") {
	logMsg( $LOG_WARN, "Please enter arguments as azure_hana_backup.pl <Backup Type> <HANA_Instance> <frequency_of_snapshot> <number_of_snapshots>." );
	exit;
}

if ($strSnapshotPrefix eq "" or $numKeep eq "" or $strHANAInstance eq "" and $strBackupType eq "boot") {
	logMsg( $LOG_WARN, "Please enter arguments as azure_hana_backup.pl boot none <frequency_of_snapshot> <number_of_snapshots>." );
	exit;
}



#Before executing the rest of the script, all HANA nodes must be accessible for scale-out
if ($strBackupType eq "hana") {
  runCheckHANAVersion();
  runCheckHANAStatus();

}

if ($strBackupType eq "vli") {
  runSetupVLIBackup();

}

# get volume(s) to take a snapshot of
runGetVolumeLocations();

#get snapshots by volume and place into array
runGetSnapshotsByVolume();
displayArray();

#if customer reduces number of snapshots as argument, this goes through and removes all that are above that number
runRemoveOlderSnapshots();

#clears snapshot locations from multi-linked array so new can be added
#now that snapshots older than numbkeep have been removed
runClearSnapshotLocations();

#get snapshots again.
runGetSnapshotsByVolume();
displayArray();

# get rid of the recent snapshot (if it exists)
runRemoveRecentSnapshot();


if ($strBackupType eq "hana") {
  # execute the HANA create snapshot command
  runCreateHANASnapshot();

  #verify status of HANA snapshot just created
  runCheckHANASnapshotStatus();
}
# execute the backup
runCreateStorageSnapshot();

# execute the HANA drop snapshot command
#runDeleteHANASnapshot();
if ($strBackupType eq "hana") {
#execute the HANA close snapshot command
    runHANACloseSnapshot();
}
# get rid of the oldest snapshot (in case of some wierd failure last time)
runRemoveOldestSnapshot("1");

# rotate snapshots before we move on to quiescing the VMs
runRotateSnapshots();

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
displayArray();

# get rid of the oldest snapshot (again, this time because we need to)
runRemoveOldestSnapshot("2");

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
displayArray();

# rename the recent snapshot
runRenameRecentSnapshot();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
displayArray();

# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
