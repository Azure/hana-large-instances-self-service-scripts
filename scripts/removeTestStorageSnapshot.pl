#!/usr/bin/perl -w
#
# 
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
# 
# Specifications subject to change without notice.
#
# Name: removeTestStorageSnapshot.pl
# Version: 2.1
# Date 09/27/2017

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
#Usage:  This script is used to test a customer's connection to the HANA database to ensure it is working correctly before attemping to run the script.
#



#
# Global Tunables

# $sshCmd             - The default SSH command to use
# $verbose            - Whether to be more verbose (or not)
# $strHANAStatusCmd   - The command to run to test status of HANA Database confirmning successful login
# $strHANAAdmin 			- The username on the HANA instance created with HANA backup credentials, typically SCADMINXX where XX is HANA instance number.
# $strHDBSQLPath			- Customer path to where application hdbsql exists
# $filename           - file name that contains customer specific static details
# $fileLines          - Array that keeps track of all lines that exist in $filename
# $arrOutputLines     - Array that keeps track of all message logs and saves them for output to file
my @arrOutputLines;
my @fileLines;
my @strSnapSplit;
my $filename = "HANABackupCustomerDetails.txt";
my $sshCmd = '/usr/bin/ssh';


#open the customer-based text file to gather required details
open(my $fh, '<:encoding(UTF-8)', $filename)
  or die "Could not open file '$filename' $!";

chomp (@fileLines=<$fh>);
close $fh;


@strSnapSplit = split(/: /, $fileLines[1]);
my $strUser = $strSnapSplit[1];
@strSnapSplit = split(/: /, $fileLines[2]);
my $strSVM = $strSnapSplit[1];
@strSnapSplit = split(/: /, $fileLines[4]);
my $strHANAAdmin = $strSnapSplit[1];



#DO NOT MODIFY THESE VARIABLES!!!!
my $verbose = 1;
my $strStorageSnapshotStatusCmd = "volume show -type RW -fields volume";
my $outputFilename = "";
my $strHANAInstance = $ARGV[0];
my @volLocations;
my @snapshotLocations;
my $strSnapshotPrefix = "testStorage";
# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE=0;
my $ERR_WARN=1;

# Log levels -- LOG_INFO, LOG_WARN.  Bitmap values
my $LOG_INFO=1;
my $LOG_WARN=2;

# Global parameters
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
# Name: runCheckHANAStatus()
# Func: Create the HANA snapshot
#
sub runCheckStorageSnapshotStatus
{
			logMsg($LOG_INFO, "**********************Checking access to Storage**********************");
			# Create a HANA database snapshot via HDBuserstore, key snapper
			my @out = runSSHCmd( $strStorageSnapshotStatusCmd );
			if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "Storage check status command '" . $strStorageSnapshotStatusCmd . "' failed: $?" );
          logMsg( $LOG_WARN, "Please check the following:");
          logMsg( $LOG_WARN, "Was publickey sent to Microsoft Service Team?");
          logMsg( $LOG_WARN, "If passphrase reqested while using ssh-keygen, publickey must be re-created and passphrase must be left blank for both entries");
          logMsg( $LOG_WARN, "Ensure correct IP address was entered in HANABackupCustomerDetails.txt");
          logMsg( $LOG_WARN, "Ensure correct Storage backup name was entered in HANABackupCustomerDetails.txt");
          logMsg( $LOG_WARN, "Ensure that no modification in format HANABackupCustomerDetails.txt like additional lines, line numbers or spacing");
					logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
					exit;
				} else {
					logMsg( $LOG_INFO, "Storage Snapshot Access successful." );
			}

}

sub runGetVolumeLocations
{
	logMsg($LOG_INFO, "**********************Getting list of volumes that match HANA instance specified**********************");
	logMsg( $LOG_INFO, "Collecting set of volumes hosting HANA matching pattern *$strHANAInstance* ..." );
	my $strSSHCmd = "volume show -volume *".$strHANAInstance."* -type RW -fields volume";
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
				$snapshotLocations[$i][0]= $name;

			}
	$i++;
	}
}

sub runGetSnapshotsByVolume
{
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
		my $i = 0;

		logMsg( $LOG_INFO, "Collecting set of snapshots for each volume hosting HANA matching pattern *$strHANAInstance* ..." );
		for my $i (1 .. $#snapshotLocations) {
				my $j = 0;
				my $strSSHCmd = "volume snapshot show -volume $snapshotLocations[$i][0] -fields snapshot";
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

sub runRemoveTestStorageSnapshot
{
logMsg($LOG_INFO, "**********************Deleting existing testStorage snapshots**********************");
	for my $i (0 .. $#snapshotLocations) {
		# let's make sure the snapshot is there first
		my $checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0], "$strSnapshotPrefix\.temp");
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

sub runCheckIfSnapshotExists
{
	my $volName = shift;
	my $snapName = shift;
	my $tempSnapName = "";
	logMsg( $LOG_INFO, "Checking if snapshot $snapName exists for $volName on SVM $strSVM ..." );

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

sub runPrintFile
{
	my $myLine;
	my $date = localtime->strftime('%Y-%m-%d_%H%M');
	$outputFilename = "StorageSnapshotStatus.$date.txt";
	my $existingdir = './statusLogs';
	mkdir $existingdir unless -d $existingdir; # Check if dir exists. If not create it.
	open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
	foreach $myLine (@arrOutputLines) {
		print $fileHandle $myLine;


	}
	close $fileHandle;




}


##### --------------------- MAIN CODE --------------------- #####
if ($strHANAInstance eq "") {
	logMsg( $LOG_WARN, "Please enter arguments as testStorageConnection.pl <HANA_Instance>." );
	exit;

}


# execute the HANA create snapshot command
runCheckStorageSnapshotStatus();

# get volume(s) to take a snapshot of based on HANA instance provided
runGetVolumeLocations();

runGetSnapshotsByVolume();

# execute a storage snapshot of empty volume to create values
runRemoveTestStorageSnapshot();
displayArray();

# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
