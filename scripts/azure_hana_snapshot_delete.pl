#!/usr/bin/perl -w
#
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
# 
# Specifications subject to change without notice.
#
# Name: azure_hana_snapshot_delete.pl
# Version: 3.0
# Date 01/27/2018

use strict;
use warnings;
use Time::Piece;
use Date::Parse;

#Usage:  This script is used to allow Azure HANA customers to delete on-demand backups that were taken with the script azure_hana_backup.pl.



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
my @HANASnapshotLocations;
my $strDeleteType;
my $strBackupid;
my $strSnapshotName;
my $strVolumeLoc;
my $boolBackupidFound;

my @addressLocations;
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
my $strHANAInstance;

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

#
# Name: runGetVolumeLocations()
# Func: Get the set of production volumes that match specified HANA instance.
#
sub runDeleteSnapshot
{

  my $strVolumeInput = "Please enter either the volume location of the snapshot you wish to delete: ";
  logMsg($LOG_INFO, $strVolumeInput);
  push (@arrOutputLines, $strVolumeInput);
  my $inputVolumeLoc = <STDIN>;
  $inputVolumeLoc  =~ s/[\n\r\f\t]//g;
  $strVolumeLoc = $inputVolumeLoc;


  #logMsg( $LOG_INPUT, "Please enter either the HANA Instance you wish to delete:" );
  my $strSnapshotInput = "Please enter either the snapshot you wish to delete:   ";
  logMsg($LOG_INFO, $strSnapshotInput);
  push (@arrOutputLines, $strSnapshotInput);
  my $inputSnapshotName = <STDIN>;
  $inputSnapshotName =~ s/[\n\r\f\t]//g;
  $strSnapshotName = $inputSnapshotName;

  my $inputProceedSnapshot;
  my $strProceedSnapshot = "You have requested to delete snapshot $strSnapshotName from volume $strVolumeLoc. Any data that exists only on this snapshot is lost forever. Do you wish to proceed (yes/no)?   ";
  logMsg($LOG_INFO,$strProceedSnapshot);
  push (@arrOutputLines, $strProceedSnapshot);
  do {
    print "Please enter (yes/no):  ";
    $inputProceedSnapshot = <STDIN>;
    $inputProceedSnapshot =~ s/[\n\r\f\t]//g;
    if ($inputProceedSnapshot =~ m/no/i) {
      exit;
    }
  } while ($inputProceedSnapshot !~ m/yes/i);



  logMsg($LOG_INFO, "*********************Deleting Snapshot $strSnapshotName from Volume $strVolumeLoc**********************");

  my $strSSHCmd = "volume snapshot show -volume $strVolumeLoc -snapshot $strSnapshotName -fields create-time";
  my @out = runSSHCmd( $strSSHCmd );
  if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
           return( 0 );
  }
  my @strSubArr = split( /,/, $out[3] );
  my $strSnapshotTime = $strSubArr[3];

  my $checkSnapshotAge = runCheckSnapshotAge($strSnapshotTime);
  if ($checkSnapshotAge) {
            my $strSSHCmd = "volume snapshot delete -volume $strVolumeLoc -snapshot $strSnapshotName";
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
                logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
            } else {
                logMsg( $LOG_INFO, "Snapshot $strSnapshotName of volume $strVolumeLoc was successfully deleted" );
            }

   } else {
            logMsg( $LOG_INFO, "$strSnapshotName is aged less than one hour... cannot delete due to potential replica interference. Stopping execution." );
            exit;
        }
}


sub runDeleteHANASnapshot
{
  my $strBackupidInput = "Please enter either the backup id of the HANA Storage Snapshot you wish to delete: ";
  logMsg($LOG_INFO, $strBackupidInput);
  push (@arrOutputLines, $strBackupidInput);
  my $inputBackupid = <STDIN>;
  $inputBackupid   =~ s/[\n\r\f\t]//g;
  $strBackupid = $inputBackupid;


  my $inputProceedHANASnapshot;
  my $strProceedHANASnapshot = "You have requested to delete all snapshots associated with HANA Backup ID $strBackupid. Any data that exists solely on these snapshots are lost forever. Do you wish to proceed (yes/no)?   ";
  logMsg($LOG_INFO,$strProceedHANASnapshot);
  push (@arrOutputLines, $strProceedHANASnapshot);
  do {
    print "Please enter (yes/no):  ";
    $inputProceedHANASnapshot = <STDIN>;
    $inputProceedHANASnapshot =~ s/[\n\r\f\t]//g;
    if ($inputProceedHANASnapshot =~ m/no/i) {
      exit;
    }
  } while ($inputProceedHANASnapshot !~ m/yes/i);

  #get the list of volumes in the tenant
  runGetVolumeLocations();

  #get snapshots in the volume
  runGetSnapshotsByVolume();

  #get the hanabackupid, if exists, for all snapshots
  runGetSnapshotDetailsBySnapshot();

  runVerifyHANASnapshot();
  if ($boolBackupidFound) {
    for my $x (0 .. $#HANASnapshotLocations) {
      my $strSSHCmd = "volume snapshot show -volume $HANASnapshotLocations[$x][0] -snapshot $HANASnapshotLocations[$x][1] -fields create-time";
      my @out = runSSHCmd( $strSSHCmd );
      if ( $? ne 0 ) {
              logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              return( 0 );
            }
      my @strSubArr = split( /,/, $out[3] );
      my $strSnapshotTime = $strSubArr[3];
      logMsg($LOG_INFO,"Checking time stamp for snapshot $HANASnapshotLocations[$x][1] of volume $HANASnapshotLocations[$x][0]");
      my $checkSnapshotAge = runCheckSnapshotAge($strSnapshotTime);
      if ($checkSnapshotAge) {
                my $strSSHCmd = "volume snapshot delete -volume $HANASnapshotLocations[$x][0] -snapshot $HANASnapshotLocations[$x][1]";
                my @out = runSSHCmd( $strSSHCmd );
                if ( $? ne 0 ) {
                    logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                } else {
                    logMsg( $LOG_INFO, "Snapshot $HANASnapshotLocations[$x][1] of volume $HANASnapshotLocations[$x][0] was successfully deleted" );
                }

       } else {
               logMsg( $LOG_INFO, "$HANASnapshotLocations[$x][1] is aged less than one hour... cannot delete due to potential replica interference. Stopping execution." );
              exit;
      }

    }
  } else {
      logMsg($LOG_INFO, "No snapshots found that correspond to HANA Backup id $strBackupid.  Please double-check the HANA Backup ID as specified in HANA Studio and try again.  If you feel you are reaching this message in error, please open a ticket with MS Operations for additional support.")

  }
}

sub runGetVolumeLocations
{
	logMsg($LOG_INFO, "**********************Getting list of volumes****************************");
	my $strSSHCmd = "volume show -volume *data* | *log* | *shared* -volume !*log_backups* -volume !*dp* -type *rw* -fields volume";
	my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Retrieving volumes failed.  Exiting script.");
    exit;
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
				push( @volLocations, $name);

			}
	$i++;
	}
}

sub runGetSnapshotsByVolume
{
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
		my $i = 0;
    my $k = 0;
		logMsg( $LOG_INFO, "Collecting set of snapshots for each volume..." );
		foreach my $volName ( @volLocations ) {
				my $j = 0;
				$snapshotLocations[$i][0][0] = $volName;
				my $strSSHCmd = "volume snapshot show -volume $volName -fields snapshot";
				my @out = runSSHCmd( $strSSHCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_INFO, "Running '" . $strSSHCmd . "' failed: $?" );
            logMsg( $LOG_INFO, "Possible reason: No snapshots were found for volume: $volName.");
            next;
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
              if (index($strSub, "snapmirror") == -1) {
                #print $strSub
                logMsg( $LOG_INFO, "Snapshot $strSub added to $snapshotLocations[$i][0][0]");
                $snapshotLocations[$i][$j][0] = $strSub;
              }
        }
				$i++;
		}

}

sub runGetSnapshotDetailsBySnapshot
{
logMsg($LOG_INFO, "**********************Adding snapshot details to snapshot list**********************");

		logMsg( $LOG_INFO, "Collecting backupids for each snapshot." );
    for my $x (0 .. $#snapshotLocations) {
           my $aref = $snapshotLocations[$x];
           for my $y (1.. $#{$aref} ) {


             my $strSSHCmd = "volume snapshot show -volume $snapshotLocations[$x][0][0] -snapshot $snapshotLocations[$x][$y][0] -fields snapshot, comment";
				     my @out = runSSHCmd( $strSSHCmd );

             if ( $? ne 0 ) {
						         logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
						          return( 0 );
				     }
							my @strSubArr = split( /,/, $out[3] );
							my $strSub = $strSubArr[$#strSubArr-1];
              $snapshotLocations[$x][$y][1] = $strSub;
				      }

		       }
}

sub runVerifyHANASnapshot
{
logMsg($LOG_INFO, "**********************Seeking backup id in found Storage Snapshots**********************");
         my $k=0;
         for my $i (0 .. $#snapshotLocations) {
                my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref} ) {
                    if (defined($snapshotLocations[$i][$j][1])) {
                         if ($snapshotLocations[$i][$j][1] eq $strBackupid) {
                           $boolBackupidFound = 1;
                           $HANASnapshotLocations[$k][0] = $snapshotLocations[$i][0][0];
                           $HANASnapshotLocations[$k][1] = $snapshotLocations[$i][$j][0];
                           logMsg($LOG_INFO,"Adding Snapshot $HANASnapshotLocations[$k][1] from volume $HANASnapshotLocations[$k][0]");
                           $k++;
                         }
                    }
                }
         }

}

sub runCheckSnapshotAge
{

  my $snapshotTimeStamp = shift;
#	logMsg($LOG_INFO, "From NetApp: $snapshotTimeStamp");
  $snapshotTimeStamp =~ tr/"//d;
#  logMsg($LOG_INFO, "Real Time Stamp: $snapshotTimeStamp");

  my $t = Time::Piece->strptime($snapshotTimeStamp, "%a %b %d %H:%M:%S %Y");
  my $tNum = str2time($t);

	my $currentTime = localtime->strftime('%Y-%m-%d_%H%M');
	my $currentT = Time::Piece->strptime($currentTime,'%Y-%m-%d_%H%M');
#  logMsg($LOG_INFO, "Current System Time: $currentTime");
	my $currentTNum = str2time($currentT);
#	logMsg($LOG_INFO,"Numeric time for snapshot: $tNum");
#	logMsg($LOG_INFO,"Numeric current time: $currentTNum");

if ((str2time($currentT)-str2time($t))>3600) {
      logMsg($LOG_INFO,"Time threshold passed.  Okay to proceed in snapshot deletion");
      return 1;
	} else {
			return 0;
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
my $strSnapshotDeleteMessage = "This script is intended to delete either a single snapshot or all snapshots that pertain to a particular HANA storage snapshot by its HANA Backup ID
found in HANA Studio.  A snapshot cannot be deleted if it is less than an hour old as deletion can interfere with replication. Please enter whether you wish to delete by backupid
or snapshot, and, if by snapshot, enter the volume name and snapshot name where the snapshot is found.  The azure_hana_snapshot_details script may be used to identify individual
snapshot names and volume locations.";

logMsg($LOG_INFO, $strSnapshotDeleteMessage);
push(@arrOutputLines,$strSnapshotDeleteMessage);
print "\n";

my $strTypeInput = "Do you want to delete by snapshot name or by HANA backup id?";
logMsg($LOG_INFO, $strTypeInput);
push (@arrOutputLines, $strTypeInput);

my $inputDeleteType;
do {
  print "Please enter (backupid/snapshot/quit): ";
  $inputDeleteType = <STDIN>;
  $inputDeleteType =~ s/[\n\r\f\t]//g;
  logMsg($LOG_INFO, "input: $inputDeleteType");
  if ($inputDeleteType =~ m/backupid/i) {
    #print "matched backupid\n";
    runDeleteHANASnapshot();
    # if we get this far, we can exit cleanly
    logMsg( $LOG_INFO, "Command completed successfully." );


    runPrintFile();
    # time to exit
    runExit( $ERR_NONE );
    exit;
  }
  if ($inputDeleteType =~ m/snapshot/i) {
    #print "matched snapshot\n";
    runDeleteSnapshot();
    # if we get this far, we can exit cleanly
    logMsg( $LOG_INFO, "Command completed successfully." );


    runPrintFile();
    # time to exit
    runExit( $ERR_NONE );
    exit;
  }
} while ($inputDeleteType !~ m/quit/i);



  runDeleteSnapshot();

  # if we get this far, we can exit cleanly
  logMsg( $LOG_INFO, "Command completed successfully." );


  runPrintFile();
  # time to exit
  runExit( $ERR_NONE );



# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
