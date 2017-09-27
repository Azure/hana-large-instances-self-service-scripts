#!/usr/bin/perl -w
#
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
# 
# Specifications subject to change without notice.
#
# Name: azure_hana_replication_status.pl
# Version: 2.1
# Date 09/27/2017

use strict;
use warnings;
use Time::Piece;
use Date::Parse;

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
my @snapshotRestorationList;
my @replicationList;
my $strHANABackupID;
my $inputRestoration;
my $inputTypeRestoration;
my $logBackupsVolume;
my $logBackupsSnapshot;
my @snapMirrorLocations;
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
my $sshCmd = '/usr/bin/ssh';
my $verbose = 1;
my $strHANAInstance = $ARGV[0];

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
my @snapshotDetails;
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


sub runGetSnapmirrorRelationships
{
	logMsg($LOG_INFO, "**********************Getting list of replication relationships that match HANA instance provided**********************");
	logMsg( $LOG_INFO, "Collecting set of relationships hosting HANA matching pattern *$strHANAInstance* ..." );
	my $strSSHCmd = "snapmirror show -destination-volume *dp* -destination-volume *".$strHANAInstance."* -fields destination-volume, status, state, lag-time, last-transfer-size, newest-snapshot";
	my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Retrieving replication relationships failed.  Please check to make sure that $strHANAInstance is the correct HANA instance.  Otherwise, please contact MS Operations for assistance with Disaster Recovery failover.");
    exit;
  } else {
		logMsg( $LOG_INFO, "Relationship show completed successfully." );
	}
  my $j=0;
	my $listnum = 0;
	my $count = $#out - 1;
	for my $i (0 ... $count ) {

    $listnum++;
		next if ( $listnum <= 3 );
		chop $out[$i];

    my @arr = split( /,/, $out[$i] );
#    print $out[$i]."\n";
#    logMsg( $LOG_INFO, @arr);
    print "volume expected:".$arr[2]."\n";
    $snapMirrorLocations[$j][0]=$arr[2];
    $snapMirrorLocations[$j][1]=$arr[3];
    $snapMirrorLocations[$j][2]=$arr[4];
    $snapMirrorLocations[$j][3]=$arr[5];
    $snapMirrorLocations[$j][4]=$arr[6];
    $snapMirrorLocations[$j][5]=$arr[7];
    $j++;
  }
}
sub displayArray
{
logMsg($LOG_INFO, "**********************Displaying Snapshots by Volume**********************");
         for my $i (0 .. $#snapMirrorLocations) {

                    if ($snapMirrorLocations[$i][0] =~ /data/) {

                         logMsg($LOG_INFO,$snapMirrorLocations[$i][0]);
                         logMsg($LOG_INFO,"-------------------------------------------------");
                         if ($snapMirrorLocations[$i][1] =~ /Broken-off/) {
                           logMsg($LOG_INFO,"Link Status: Broken-Off");
                         } else {
                           logMsg($LOG_INFO,"Link Status: Active");
                         }
                         logMsg($LOG_INFO,"Current Replication Activity: ".$snapMirrorLocations[$i][2]);
                         logMsg($LOG_INFO,"Latest Snapshot Replicated: ".$snapMirrorLocations[$i][3]);
                         logMsg($LOG_INFO,"Size of Latest Snapshot Replicated: ".$snapMirrorLocations[$i][4]);
                         logMsg($LOG_INFO,"Current Lag Time between snapshots: ".$snapMirrorLocations[$i][5]. "   ***Less than 90 minutes is acceptable***");
                         logMsg($LOG_INFO,"*************************************************");

                    }
                    if ($snapMirrorLocations[$i][0] =~ /log/) {

                         logMsg($LOG_INFO,$snapMirrorLocations[$i][0]);
                         logMsg($LOG_INFO,"-------------------------------------------------");
                         if ($snapMirrorLocations[$i][1] =~ /Broken-off/) {
                           logMsg($LOG_INFO,"Link Status: Broken-Off");
                         } else {
                           logMsg($LOG_INFO,"Link Status: Active");
                         }
                         logMsg($LOG_INFO,"Current Replication Activity: ".$snapMirrorLocations[$i][2]);
                         logMsg($LOG_INFO,"Latest Snapshot Replicated: ".$snapMirrorLocations[$i][3]);
                         logMsg($LOG_INFO,"Size of Latest Snapshot Replicated: ".$snapMirrorLocations[$i][4]);
                         logMsg($LOG_INFO,"Current Lag Time between snapshots: ".$snapMirrorLocations[$i][5]. "   ***Less than 20 minutes is acceptable***");
                         logMsg($LOG_INFO,"*************************************************");

                    }
                    if ($snapMirrorLocations[$i][0] =~ /shared/) {

                         logMsg($LOG_INFO,$snapMirrorLocations[$i][0]);
                         logMsg($LOG_INFO,"-------------------------------------------------");
                         if ($snapMirrorLocations[$i][1] =~ /Broken-off/) {
                           logMsg($LOG_INFO,"Link Status: Broken-Off");
                         } else {
                           logMsg($LOG_INFO,"Link Status: Active");
                         }
                         logMsg($LOG_INFO,"Current Replication Activity: ".$snapMirrorLocations[$i][2]);
                         logMsg($LOG_INFO,"Latest Snapshot Replicated: ".$snapMirrorLocations[$i][3]);
                         logMsg($LOG_INFO,"Size of Latest Snapshot Replicated: ".$snapMirrorLocations[$i][4]);
                         logMsg($LOG_INFO,"Current Lag Time between snapshots: ".$snapMirrorLocations[$i][5]. "   ***Less than 90 minutes is acceptable***");
                         logMsg($LOG_INFO,"*************************************************");

                    }
          }
}



sub runPrintFile
{
	my $myLine;
	my $date = localtime->strftime('%Y-%m-%d_%H%M');
	$outputFilename = "$date.txt";
	my $existingdir = './snapshotLogs';
	mkdir $existingdir unless -d $existingdir; # Check if dir exists. If not create it.
	open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
	foreach $myLine (@arrOutputLines) {
		print $fileHandle $myLine;


	}
	close $fileHandle;
}

##### --------------------- MAIN CODE --------------------- #####
if ($strHANAInstance eq "" ) {
	logMsg( $LOG_WARN, "Please enter arguments as replication_status.pl <HANA_Instance>." );
	exit;

}


#my $strHello = "This script is designed for those customers who have previously installed the Production HANA instance in the Disaster Recovery Location either as a stand-alone instace or as part of a multi-purpose environment. This script will accept input for several entries before executing and providing back appropriate storage mounts that must be included in the /etc/fstab before proceeding.  Additionally, great care must be taken in ensuring that the proper HANA Backup ID or snapshot name is provided.  If an incorrect entry is provided, then data loss might occur as newer snapshots than the one restored are removed as part of the restoration process.  This script must be executed from the Disaster Recovery location otherwise unintended actions may occur. Do you wish to proceed (yes/no)?   ";

#verify either HANA Backup ID or snapshot name is found


# get volume(s) to take a snapshot of
runGetSnapmirrorRelationships();
displayArray();





# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
