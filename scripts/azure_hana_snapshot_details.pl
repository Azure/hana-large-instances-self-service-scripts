#!/usr/bin/perl -w
#
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
# 
# Specifications subject to change without notice.
#
# Name: azure_hana_backup.pl
# Version: 2.0
# Date 08/11/2017

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
my @arrOutputLines;
my @fileLines;
my @strSnapSplit;
my @customerDetails;
my $strHANABackupID;
my $strExternalBackupID;
#my $filename = "/usr/sap/".$strHANAInstance."/HDB".$strHANAInstanceNumber."/exe/HANABackupCustomerDetails.txt";
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





#DO NOT MODIFY THESE VARIABLES!!!!
my $numKeep = $ARGV[4];
my $sshCmd = '/usr/bin/ssh';
my $verbose = 1;
my $strBackupType = $ARGV[0];
my $strHANAInstance = $ARGV[1];
my $strHANAInstanceNumber = $ARGV[2];
my $strSnapshotPrefix = $ARGV[3];

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
  push (@arrOutputLines, $str);
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
# Name: runGetVolumeLocations()
# Func: Get all volumes that belong to the tenant
#
sub runGetVolumeLocations
{

  logMsg($LOG_INFO, "**********************Getting list of all customer volumes**********************");
  my $strSSHCmd = "volume show -type RW -fields volume";
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
				logMsg( $LOG_INFO, "Adding volume $name to the volumes list." );
				push( @volLocations, $name );

			}
	$i++;
	}
}

#
# Name: runGetSnapshotsByVolume()
# Func: Get the list of snapshots for each volume.
#

sub runGetSnapshotsByVolume
{
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
		my $i = 0;

    foreach my $volName ( @volLocations ) {
				my $j = 0;

				my $strSSHCmd = "volume snapshot show -volume $volName -fields snapshot";
				my @out = runSSHCmd( $strSSHCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_INFO, "Running '" . $strSSHCmd . "' failed: $?" );
            logMsg( $LOG_INFO, "Possible reason: Volume $volName does not contain any snapshots!" );
            next;
        }
        $snapshotLocations[$i][0][0] = $volName;
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
              logMsg($LOG_INFO,"Snapshot name:   $strSub");
              $snapshotLocations[$i][$j][0] = $strSub;
				}
				$i++;
		}

}

sub runGetSnapshotDetailsBySnapshot
{

  logMsg($LOG_INFO, "**********************Adding snapshot details to snapshot list**********************");


      for my $x (0 .. $#snapshotLocations) {
             my $aref = $snapshotLocations[$x];
             for my $y (1.. $#{$aref} ) {

               Time::HiRes::sleep (0.5+rand(0.5));
               logMsg($LOG_INFO,"Obtaining Snapshot $snapshotLocations[$x][$y][0] details for volume $snapshotLocations[$x][0][0]");
               my $strSSHCmd = "volume snapshot show -volume $snapshotLocations[$x][0][0] -snapshot $snapshotLocations[$x][$y][0] -fields snapshot,size,create-time,comment,snapmirror-label";
  				     my @out = runSSHCmd( $strSSHCmd );

               if ( $? ne 0 ) {
  						         logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
  						          return( 0 );
  				     }
  							my @strSubArr = split( /,/, $out[3] );
                #logMsg($LOG_INFO,$strSubArr);
                my $strSubCreateTime = $strSubArr[$#strSubArr-4];
                my $strSubSize = $strSubArr[$#strSubArr-3];
                my $strSubHanaBackupID = $strSubArr[$#strSubArr-2];
                my $strSubFrequency = $strSubArr[$#strSubArr-1];
                logMsg($LOG_INFO,"create time: $strSubCreateTime");
                logMsg($LOG_INFO,"size: $strSubSize");
                logMsg($LOG_INFO,"HanaBackupID: $strSubHanaBackupID");
                logMsg($LOG_INFO,"frequency: $strSubFrequency");


                $snapshotLocations[$x][$y][1] = $strSubCreateTime;
                $snapshotLocations[$x][$y][2] = $strSubSize;
                $snapshotLocations[$x][$y][3] = $strSubHanaBackupID;
  		          $snapshotLocations[$x][$y][4] = $strSubFrequency;
              }
            }
}


sub displaySnapshotArray
{
logMsg($LOG_INFO, "**********************Displaying Snapshots by Volume**********************");
         for my $i (0 .. $#snapshotLocations) {
                my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref} ) {

                         logMsg($LOG_INFO,$snapshotLocations[$i][$j][0]);
                 }
         }

}


sub displaySnapshotArrayDetails
{
logMsg($LOG_INFO, "**********************Displaying Snapshot Details by Volume**********************");
        my $t = 1;


            for my $i (0 .. $#snapshotLocations) {
              logMsg($LOG_INFO,"**********************************************************");
              logMsg($LOG_INFO,"****Volume: $snapshotLocations[$i][0][0]       ***********");
              logMsg($LOG_INFO,"**********************************************************");
              my $strSSHCmd = "volume show -volume $snapshotLocations[$i][0][0] -fields size-used-by-snapshots";
      				my @out = runSSHCmd( $strSSHCmd );
              if ( $? ne 0 ) {
                      logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                       return( 0 );
              }
              my @strSubArr = split( /,/, $out[3] );
              my $strVolTotalSnapshotSize = $strSubArr[2];

              logMsg($LOG_INFO,"Total Snapshot Size:  ".  $strVolTotalSnapshotSize);
              my $aref = $snapshotLocations[$i];
              for my $j (1 .. $#{$aref} ) {
                      logMsg($LOG_INFO,"----------------------------------------------------------");
                      logMsg($LOG_INFO,"Snapshot:   $snapshotLocations[$i][$j][0]");
                      logMsg($LOG_INFO,"Create Time:   $snapshotLocations[$i][$j][1]");
                      logMsg($LOG_INFO,"Size:   $snapshotLocations[$i][$j][2]");
                      logMsg($LOG_INFO,"Frequency:   $snapshotLocations[$i][$j][4]");
                      if (defined $snapshotLocations[$i][$j][3]) {
                        logMsg($LOG_INFO,"HANA Backup ID:   $snapshotLocations[$i][$j][3]");
                      }
              }
            }
}



sub runPrintFile
{
	my $myLine;
	my $date = localtime->strftime('%Y-%m-%d_%H%M');
	$outputFilename = "SnapshotDetails.$date.txt";
	my $existingdir = './snapshotLogs';
	mkdir $existingdir unless -d $existingdir; # Check if dir exists. If not create it.
	open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
	foreach $myLine (@arrOutputLines) {
		print $fileHandle $myLine;


	}
	close $fileHandle;
}

##### --------------------- MAIN CODE --------------------- #####
# get volume(s) to take a snapshot of
runGetVolumeLocations();

#get snapshots by volume and place into array
runGetSnapshotsByVolume();
displaySnapshotArray();

#get snapshot details for each snapshot found
runGetSnapshotDetailsBySnapshot();
displaySnapshotArrayDetails();

# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
