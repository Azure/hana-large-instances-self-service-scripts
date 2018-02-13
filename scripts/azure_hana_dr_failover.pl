#!/usr/bin/perl -w
#
# Copyright (C) 2017 Microsoft, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: azure_hana_dr_failover.pl 
# Version: 3.1 
# Date 01/27/2018 

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Time::HiRes;
use Term::ANSIColor;
#number of allowable SIDs. Number entered is one less than actual.. i.e if allowing 4 SIDs, then 3 is entered
my $numSID = 9;
my $detailsStart = 13;
#Usage:  This script is intended to allow customers to automate the failover of their Production instance from their Production location to
#their Disaster Recovery location.  The script breaks the SnapMirror relationship between the two locations, restores the latest snapshot for
#the data and log backups volume, and provides the mount point details for the DR build.
#
# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE=0;
my $ERR_WARN=1;

# Log levels -- LOG_INFO, LOG_WARN.  Bitmap values
my $LOG_INFO=1;
my $LOG_WARN=2;

# Global parameters

my $exitWarn = 0;
my $exitCode;

my $verbose = 1;
my $sshCmd = '/usr/bin/ssh';

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
my $outputFilename = "";
my @snapshotRestorationList;
my @replicationList;
my $strHANAServerName;
my $strHANAServerIPAddress;
my @arrCustomerDetails;
my $strHANABackupID;
my $inputRestoration;
my $inputTypeRestoration;
my $logBackupsVolume;
my $logBackupsSnapshot;
my $strUser;
my $strSVM;
my @addressLocations;
my @snapshotLocations;
my @volLocations;
my @qtreeLocations;
my $strHANAInstance;
my $filename = "HANABackupCustomerDetails.txt";
#open the customer-based text file to gather required details
#open the customer-based text file to gather required details
sub runOpenParametersFiles {
  open(my $fh, '<:encoding(UTF-8)', $filename)
    or die "Could not open file '$filename' $!";

  chomp (@fileLines=<$fh>);
  close $fh;
}

sub runVerifyParametersFile {

  my $k = $detailsStart;
  my $lineNum;
  $lineNum = $k-3;
  my $stringServerName = "HANA Server Name:";
  if ($fileLines[$lineNum-1]) {
    if (index($fileLines[$lineNum-1],$stringServerName) eq -1) {
      logMsg($LOG_WARN, "Expected ".$stringServerName);
      logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting");
      exit;
    }
  }


  $lineNum = $k-2;
  my $stringHANAIPAddress = "HANA Server IP Address:";
  if ($fileLines[$lineNum-1]) {
    if (index($fileLines[$lineNum-1],$stringHANAIPAddress) eq -1) {
      logMsg($LOG_WARN, "Expected ".$stringHANAIPAddress);
      logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting");
      exit;
    }
  }



  for my $i (0 ... $numSID) {

        my $j = $i*9;
        $lineNum = $k+$j;
        my $string1 = "######***SID #".($i+1)." Information***#####";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string1) eq -1) {
            logMsg($LOG_WARN, "Expected ".$string1);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string2 = "SID".($i+1);
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string2) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string2);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string3 = "###Provided by Microsoft Operations###";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string3) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string3);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string4 = "SID".($i+1)." Storage Backup Name:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string4) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string4);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting.");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string5 = "SID".($i+1)." Storage IP Address:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string5) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string5);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting.");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string6 = "######     Customer Provided    ######";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string6) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string6);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting.");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string7 = "SID".($i+1)." HANA instance number:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string7) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string7);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting.");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string8 = "SID".($i+1)." HANA HDBuserstore Name:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string8) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string8);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting.");
            exit;
          }
        }
        $j++;
        $lineNum = $k+$j;
        if ($#fileLines >= $lineNum-1 and $fileLines[$lineNum-1]) {
          if ($fileLines[$lineNum-1] ne "") {
            logMsg($LOG_WARN, "Expected Blank Line");
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting.");
            exit;
            }
          }
      }
}

sub runGetParameterDetails {

  my $k = $detailsStart;
  #HANA Server Name
  my $lineNum;
  $lineNum = $k-3;
  if (substr($fileLines[$lineNum-1],0,1) ne "#") {
    @strSnapSplit = split(/:/, $fileLines[$lineNum-1]);
  } else {
    logMsg($LOG_WARN,"Cannot skip HANA Server Name. It is a required field");
    exit;
  }
  if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
    $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
    $strHANAServerName = $strSnapSplit[1];
    logMsg($LOG_INFO,"HANA Server Name: ".$strHANAServerName);
  }

  undef @strSnapSplit;
  #HANA SERVER IP Address
  $lineNum = $k-2;
  if (substr($fileLines[$lineNum-1],0,1) ne "#") {
    @strSnapSplit = split(/:/, $fileLines[$lineNum-1]);
  } else {
    logMsg($LOG_WARN,"Cannot skip HANA Server IP Address. It is a required field");
    exit;
  }
  if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
    $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
    $strHANAServerIPAddress = $strSnapSplit[1];
    logMsg($LOG_INFO,"HANA Server IP Address: ".$strHANAServerIPAddress);
  }

  for my $i (0 .. $numSID) {

    my $j = ($detailsStart+$i*9);
    undef @strSnapSplit;

    if (!$fileLines[$j]) {
      next;
    }

    #SID
    if (substr($fileLines[$j],0,1) ne "#") {
      @strSnapSplit = split(/:/, $fileLines[$j]);
    } else {
      $arrCustomerDetails[$i][0] = "Skipped";
      logMsg($LOG_INFO,"SID".($i+1).": ".$arrCustomerDetails[$i][0]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][0] = lc $strSnapSplit[1];
      logMsg($LOG_INFO,"SID".($i+1).": ".$arrCustomerDetails[$i][0]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][0]) {
            $arrCustomerDetails[$i][0] = "Omitted";
            logMsg($LOG_INFO,"SID".($i+1).": ".$arrCustomerDetails[$i][0]);

    }

    #Storage Backup Name
    if (substr($fileLines[$j+2],0,1) ne "#") {
    @strSnapSplit = split(/:/, $fileLines[$j+2]);
    } else {
      $arrCustomerDetails[$i][1] = "Skipped";
      logMsg($LOG_INFO,"Storage Backup Name: ".$arrCustomerDetails[$i][1]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][1] = lc $strSnapSplit[1];
      logMsg($LOG_INFO,"Storage Backup Name: ".$arrCustomerDetails[$i][1]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][1]) {
            $arrCustomerDetails[$i][1] = "Omitted";
            logMsg($LOG_INFO,"Storage Backup Name: ".$arrCustomerDetails[$i][1]);

    }

    #Storage IP Address
    if (substr($fileLines[$j+3],0,1) ne "#") {
      @strSnapSplit = split(/:/, $fileLines[$j+3]);
    } else {
      $arrCustomerDetails[$i][2] = "Skipped";
      logMsg($LOG_INFO,"Storage Backup Name: ".$arrCustomerDetails[$i][2]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][2] = $strSnapSplit[1];
      logMsg($LOG_INFO,"Storage IP Address: ".$arrCustomerDetails[$i][2]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][2]) {
            $arrCustomerDetails[$i][2] = "Omitted";
            logMsg($LOG_INFO,"Storage Backup Name: ".$arrCustomerDetails[$i][2]);

    }

    #HANA Instance Number
    if (substr($fileLines[$j+5],0,1) ne "#") {
      @strSnapSplit = split(/:/, $fileLines[$j+5]);
    } else {
      $arrCustomerDetails[$i][3] = "Skipped";
      logMsg($LOG_INFO,"HANA Instance Number: ".$arrCustomerDetails[$i][3]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][3] = $strSnapSplit[1];
      logMsg($LOG_INFO,"HANA Instance Number: ".$arrCustomerDetails[$i][3]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][3]) {
            $arrCustomerDetails[$i][3] = "Omitted";
            logMsg($LOG_INFO,"HANA Instance Number: ".$arrCustomerDetails[$i][3]);

    }

    #HANA User name
    if (substr($fileLines[$j+6],0,1) ne "#") {
      @strSnapSplit = split(/:/, $fileLines[$j+6]);
    } else {
      $arrCustomerDetails[$i][4] = "Skipped";
      logMsg($LOG_INFO,"HANA Instance Number: ".$arrCustomerDetails[$i][4]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][4] = uc $strSnapSplit[1];
      logMsg($LOG_INFO,"HANA Userstore Name: ".$arrCustomerDetails[$i][4]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][4]) {
            $arrCustomerDetails[$i][4] = "Omitted";
            logMsg($LOG_INFO,"HANA Instance Number: ".$arrCustomerDetails[$i][4]);

    }
  }
}

sub runVerifySIDDetails {


NUMSID:    for my $i (0 ... $numSID) {
      my $checkSID = 1;
      my $checkBackupName = 1;
      my $checkIPAddress = 1;
      my $checkHANAInstanceNumber = 1;
      my $checkHANAUserstoreName = 1;

      for my $j (0 ... 4) {
        if (!$arrCustomerDetails[$i][$j]) { last NUMSID; }
      }

      if ($arrCustomerDetails[$i][0] eq "Omitted") {
          $checkSID = 0;
      }
      if ($arrCustomerDetails[$i][1] eq "Omitted") {
          $checkBackupName = 0;
      }
      if ($arrCustomerDetails[$i][2] eq "Omitted") {
          $checkIPAddress = 0;
      }
      if ($arrCustomerDetails[$i][3] eq "Omitted") {
          $checkHANAInstanceNumber = 0;
      }
      if ($arrCustomerDetails[$i][4] eq "Omitted") {
          $checkHANAUserstoreName = 0;
      }

      if ($checkSID eq 0 and $checkBackupName eq 0 and $checkIPAddress eq 0 and $checkHANAInstanceNumber eq 0 and $checkHANAUserstoreName eq 0) {
        next;
      } elsif ($checkSID eq 1 and $checkBackupName eq 1 and $checkIPAddress eq 1 and $checkHANAInstanceNumber eq 1 and $checkHANAUserstoreName eq 1) {
        next;
      } else {
            if ($checkSID eq 0) {
              logMsg($LOG_WARN,"Missing SID".($i+1)." Exiting.");
            }
            if ($checkBackupName eq 0) {
              logMsg($LOG_WARN,"Missing Storage Backup Name for SID".($i+1)." Exiting.");
            }
            if ($checkIPAddress eq 0) {
              logMsg($LOG_WARN,"Missing Storage IP Address for SID".($i+1)." Exiting.");
            }
            if ($checkHANAInstanceNumber eq 0) {
              logMsg($LOG_WARN,"Missing HANA Instance User Name for SID".($i+1)." Exiting.");
            }
            if ($checkHANAUserstoreName eq 0) {
              logMsg($LOG_WARN,"Missing HANA Userstore Name for SID".($i+1)." Exiting.");
            }
            exit;
        }
    }
}

#
# Name: logMsg()
# Func: Print out a log message based on the configuration.  The
#       way messages are printed are based on the type of verbosity,
#       debugging, etc.
#

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
    print color('bold red');
    print $str;
    print color('reset');
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
    if ($exitCode eq 0) {

      print color ('bold green');
      logMsg( $LOG_INFO, "Command completed successfully." );
      print color ('reset');
    }
    if ($exitCode eq 1) {

      print color ('bold red');
      logMsg( $LOG_INFO, "Command failed. Please check screen output or created logs for errors." );
      print color ('reset');
    }


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

sub runSSHDiagCmd
{
	#logMsg($LOG_INFO,"inside runSSHCmd");
	my ( $strShellCmd ) = @_;
	return(  `"$sshCmd" -l $strUser $strSVM 'set diag -confirmations off -showseparator ","; $strShellCmd' 2>&1` );
}

#
# Name: runGetVolumeLocations()
# Func: Get the set of production volumes that match specified HANA instance.
#
sub runGetVolumeLocations
{
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Getting list of volumes that match HANA instance specified**********************");
  print color('reset');
  logMsg( $LOG_INFO, "Collecting set of volumes hosting HANA matching pattern *$strHANAInstance* ..." );
	#my $strSSHCmd = "volume show -volume *".$strHANAInstance."* -volume !*log_".$strHANAInstance."* -volume !*shared* -volume *dp* -volume !*clone* -fields volume";
  my $strSSHCmd = "volume show -volume *".$strHANAInstance."* -volume !*clone* -type DP -volume !*log_".$strHANAInstance."* -volume !*shared* -fields volume,type";
  my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Retrieving volumes failed.  Please check to make sure that $strHANAInstance is the correct HANA instance.  Otherwise, please contact MS Operations for assistance with Disaster Recovery failover.");
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

			my $name = $arr[$#arr-2];
			#logMsg( $LOG_INFO, $i."-".$name );
			if (defined $name) {
				logMsg( $LOG_INFO, "Adding volume $name to the snapshot list." );
				push( @volLocations, $name);

			}
	$i++;
	}
}

sub runGetQtreeLocations
{
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Getting list of Qtrees of shared volume**********************");
  print color('reset');
  #my $strSSHCmd = "volume show -volume *".$strHANAInstance."* -volume !*log_".$strHANAInstance."* -volume !*shared* -volume *dp* -volume !*clone* -fields volume";
  foreach my $volName ( @volLocations ) {

    if ($volName =~ "shared" and $volName =~ "vol") {


    logMsg( $LOG_INFO, "Collecting set of qtrees for $volName ..." );
    my $strSSHCmd = "qtree show -volume ".$volName." -fields qtree";
    my @out = runSSHCmd( $strSSHCmd );
  	if ( $? ne 0 ) {
  		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
      logMsg( $LOG_WARN, "Retrieving qtrees failed.  Please check to make sure that $strHANAInstance is the correct HANA instance.  Otherwise, please contact MS Operations for assistance with Disaster Recovery failover.");
      exit;
    } else {
  		logMsg( $LOG_INFO, "Qtree show completed successfully." );
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
          if ($name ne '""') {
            logMsg( $LOG_INFO, "Adding qtree $name to the qtree list." );
  				  push( @qtreeLocations, $name);
          }
  			}
  	 $i++;
  	 }
   }
 }
}

sub runGetSnapshotsByVolume
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
print color('reset');
		my $i = 0;
    logMsg( $LOG_INFO, "Collecting set of snapshots for each volume hosting HANA matching pattern *$strHANAInstance* ..." );
		foreach my $volName ( @volLocations ) {
				my $j = 0;
				$snapshotLocations[$i][0] = $volName;
        if ((($volName !~ /data/ and $volName !~ /log_backups/) and $volName =~ /dp/) or $volName =~ /vol/)  {
          next;
        }
        my $strSSHDiagCmd = "snapshot show -volume $volName -snapshot !*snapmirror* -sort-by create-time -snapmirror-label hourly|3min|15min|15 -fields snapshot";
        my @out = runSSHDiagCmd( $strSSHDiagCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_WARN, "Running '" . $strSSHDiagCmd . "' failed: $?" );
            logMsg( $LOG_WARN, "No snapshots were found for volume: $volName.  Please verify you have provided the correct HANA instance.  If so, Microsoft Operations Team must be contacted to handle Disaster Recovery failover.");
            exit;
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
              my $strSub = $strSubArr[$#strSubArr-2];
              if (defined($strSub)) {
                if ($strSub !~ /snapmirror/) {
                  #print $strSub
                  $snapshotLocations[$i][$j] = $strSub;
                }
              } else {
                  $j--;
              }

        }
				$i++;
		}

}


#
# Name: runCheckIfSnapshotExists
# Func: Verify if a snapshot exists.  Return 0 if it does not, 1 if it does.
#
sub runVerifySnapshotsExist
{
	#determine whether we are looking for snapshot or HANA Backup ID
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Verifying correct number of snapshots exist for data volumes**********************");
  print color('reset');
  my $snapshotFound = 0;
  my $dataCount = 0;
  my $snapshotCount = 0;


  logMsg( $LOG_INFO, "Checking if latest snapshot name exists for HANA SID ".$strHANAInstance );

  for my $i (0 .. $#snapshotLocations) {
      logMsg($LOG_INFO,"Volume:".$snapshotLocations[$i][0]);

      if ($snapshotLocations[$i][0] =~ /data/) {
          $dataCount++;
          logMsg($LOG_INFO,"Searching volume: ".$snapshotLocations[$i][0]." for most recent snapshot");
          my $aref = $snapshotLocations[$i];
          my $j = $#{$aref};
#          for my $j (1 .. $#{$aref} ) {
          logMsg($LOG_INFO,"Snapshot:".$snapshotLocations[$i][$j]);

              if ($snapshotLocations[$i][$j] =~ /\.0/ ) {
                  $snapshotRestorationList[$snapshotCount][0] = $snapshotLocations[$i][0];
                  $snapshotRestorationList[$snapshotCount][1] =  $snapshotLocations[$i][$j];
                  $snapshotCount++;
              }

        }

    if ($snapshotLocations[$i][0] =~ /log_backups/ ) {
      logMsg($LOG_INFO,"Volume:".$snapshotLocations[$i][0]);
      logMsg($LOG_INFO,"Searching volume: ".$snapshotLocations[$i][0]." for expected latest snapshot .0");
      my $aref = $snapshotLocations[$i];
      my $j = $#{$aref};
#     for my $j (1 .. $#{$aref} ) {
      logMsg($LOG_INFO,"Snapshot:".$snapshotLocations[$i][$j]);
          if ($snapshotLocations[$i][$j] =~ /\.0/ ) {
              $logBackupsVolume = $snapshotLocations[$i][0];
              $logBackupsSnapshot = $snapshotLocations[$i][$j];
              $snapshotFound = 1;
              last;
          }
       }

     }
  if ($snapshotCount == $dataCount) {
    print color('bold green');
    logMsg($LOG_INFO,"All data volumes have correct snapshot present");
    print color('reset');

  } else  {
      logMsg($LOG_INFO,"Expected to match ".$dataCount." but found ".$snapshotCount);
      exit;


  }
  if( $snapshotFound == 0) {
      logMsg($LOG_WARN,"Most recent log_backups snapshot not found. Please contact MS Operations for further assistance");
      runExit( $ERR_WARN );
  } else {
      logMsg($LOG_INFO,"Using Log Backups Volume: ".$logBackupsVolume);
      logMsg($LOG_INFO,"Using Log Backups Snapshot: ".$logBackupsSnapshot);


  }



}

sub runGetSnapmirrorRelationships
{
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Getting list of replication relationships that match HANA instance provided**********************");
  print color('reset');
  logMsg( $LOG_INFO, "Collecting set of relationships hosting HANA matching pattern *$strHANAInstance* ..." );
	my $strSSHCmd = "snapmirror show -type dp -destination-volume *$strHANAInstance* -destination-volume !*shared* -fields destination-volume";
	my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Retrieving replication relationships failed.  Please check to make sure that $strHANAInstance is the correct HANA instance.  Otherwise, please contact MS Operations for assistance with Disaster Recovery failover.");
    exit;
  } else {
		logMsg( $LOG_INFO, "Relationship show completed successfully." );
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
				logMsg( $LOG_INFO, "Adding volume $name to the replication list." );
				push( @replicationList, $name);

			}
	$i++;
	}
}
sub runUpdateSnapMirror
{
    print color('bold cyan');
    logMsg($LOG_INFO, "**********************Updating Relationships by Volume**********************");
    print color('reset');
         for my $i (0 .. $#replicationList) {


            my $strSSHCmd = "snapmirror update -destination-vserver * -destination-volume ".$replicationList[$i];
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
          		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              logMsg( $LOG_WARN, "The replication relationship for ".$replicationList[$i]." could not be updated.  Please reach out to MS Operations for assistance");
              exit;
            } else {
          		logMsg( $LOG_INFO, "Relationship updated for volume ".$replicationList[$i]." completed successfully." );
          	}
        }
}

sub runQuiesceSnapMirror
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Quiescing Relationships by Volume**********************");
print color('reset');
         for my $i (0 .. $#replicationList) {


            my $strSSHCmd = "snapmirror quiesce -destination-vserver * -destination-volume ".$replicationList[$i];
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
          		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              logMsg( $LOG_WARN, "The replication relationship for ".$replicationList[$i]." could not be quiesced.  Please reach out to MS Operations for assistance");
              exit;
            } else {
          		logMsg( $LOG_INFO, "Relationship quiesce for volume ".$replicationList[$i]." completed successfully." );
          	}

        }
}

sub runBreakSnapMirror {

print color('bold cyan');
logMsg($LOG_INFO, "**********************Breaking Relationships by Volume**********************");
print color('reset');
         for my $i (0 .. $#replicationList) {
            my $relStatus;
            my $relState;
            do {

              my $strSSHCmd = "snapmirror show -destination-volume ".$replicationList[$i]. " -fields status, state";
              my @out = runSSHCmd( $strSSHCmd );
              my @strSubArr = split( /,/, $out[3] );
							$relState = $strSubArr[$#strSubArr-1];
              $relStatus = $strSubArr[$#strSubArr-2];
              logMsg($LOG_INFO,"Volume:   ".$replicationList[$i]."   State: ".$relState);
              #print "State: ".$relState;
              #print "    Status ".$relStatus."\n";

              if ($relStatus eq "Broken-Off") {
                  logMsg( $LOG_INFO, "The replication relationship for ".$replicationList[$i]." is already broken. Continuing with script");
                  last;
              }

            } while ($relState ne "Quiesced");
            my $strSSHCmd = "snapmirror break -destination-vserver * -destination-volume ".$replicationList[$i];
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
          		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              logMsg( $LOG_WARN, "The replication relationship for ".$replicationList[$i]." could not be broken.  Please reach out to MS Operations for assistance");
              exit;
            } else {
          		logMsg( $LOG_INFO, "Relationship broken for volume ".$replicationList[$i]." completed successfully." );
          	}

        }
}

sub runRestoreSnapshot {

print color('bold cyan');
logMsg($LOG_INFO, "**********************Restoring Snapshots by Volume**********************");
print color('reset');
        for my $i (0... $#snapshotRestorationList) {

            my $strSSHCmd = "snapshot restore -volume ".$snapshotRestorationList[$i][0]." -snapshot ".$snapshotRestorationList[$i][1]." -force true";
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
          		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              logMsg( $LOG_WARN, "Snapshot restoration for ".$snapshotRestorationList[$i][0]."  failed.  Please reach out to MS Operations for assistance");
              exit;
            } else {
          		logMsg( $LOG_INFO, "Snapshot restoration for volume ".$snapshotRestorationList[$i][0]." completed successfully." );
          	}
        }
        logMsg($LOG_INFO, "**********************All Data volumes restored sucessfully**********************");

        my $strSSHCmd = "snapshot restore -volume ".$logBackupsVolume." -snapshot ".$logBackupsSnapshot." -force true";
        if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
          logMsg( $LOG_WARN, "Snapshot restoration for ".$logBackupsVolume."  failed.  Please reach out to MS Operations for assistance");
          exit;
        } else {
          logMsg( $LOG_INFO, "Snapshot restoration for volume ".$logBackupsVolume." completed successfully." );
        }
}

sub runMountDRVolumes {

print color('bold cyan');
logMsg($LOG_INFO, "**********************Mounting Dr Volumes by Volume**********************");
print color('reset');
    for my $i (0 .. $#volLocations) {
      my $volName = $volLocations[$i];
      if ((($volName !~ /data/ and $volName !~ /log_backups/) and $volName =~ /dp/) or $volName =~ /vol/)  {
        next;
      }
      my $strSSHCmd = "volume mount -volume ".$volLocations[$i]." -junction-path /".$volLocations[$i]." -active true";
      my @out = runSSHCmd( $strSSHCmd );
      if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Volume Mount for ".$volLocations[$i]."  failed.  Please reach out to MS Operations for assistance");
        exit;
      } else {
        logMsg( $LOG_INFO, "Volume ".$volLocations[$i]." mounted successfully." );
      }

    }


}

sub runDisplayMountPoints {

    print color('bold cyan');
    logMsg($LOG_INFO, "**********************Collecting Mount Point Details**********************");
    print color('reset');
    my $strMountOptions = "nfs       rw,bg,hard,timeo=600,vers=4,rsize=1048576,wsize=1048576,intr,noatime,lock 0 0";
    my $j = 0;
    for my $i (0 .. $#volLocations) {
      my $volName = $volLocations[$i];
      if ((($volName !~ /data/ and $volName !~ /log_backups/ ) and $volName =~ /dp/) or (($volName !~ /log/ and $volName !~ /shared/ and $volName !~ /usr_sap/) and $volName =~ /vol/)) {
        next;
      }
      my $strSSHCmd = "volume show -volume ".$volLocations[$i]." -fields node";
      my @out = runSSHCmd( $strSSHCmd );
      if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Unable to find location of ".$volLocations[$i].".  Please reach out to MS Operations for assistance for IP Address.");
        exit;
      } else {
        logMsg( $LOG_INFO, "Located location of ".$volLocations[$i]);
      }
      my @strSubArr = split( /,/, $out[3] );
      my $node = $strSubArr[$#strSubArr-1];

      $strSSHCmd = "network interface show -home-node ".$node." -data-protocol nfs -fields address";
      my @outAddress = runSSHCmd( $strSSHCmd );
      if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Unable to find address of ".$volLocations[$i].".  Please reach out to MS Operations for assistance for IP Address.");
        exit;
      } else {
        logMsg( $LOG_INFO, "Address found of ".$volLocations[$i]);
      }
      my @strSubArrAddress = split( /,/, $outAddress[3] );
      my $address = $strSubArrAddress[$#strSubArrAddress-1];

      $addressLocations[$j][0] = $volLocations[$i];
      $addressLocations[$j][1] = $address;
      $j++;
    }
    print color('bold cyan');
    logMsg($LOG_INFO, "**********************Displaying Mount Points by Volume**********************");
    print color('reset');
    my $mountNode;
    my $strHANASID = uc $strHANAInstance;
    for my $i (0 .. $#addressLocations) {

                #logMsg($LOG_INFO,$addressLocations[$i][0]);
                if ($addressLocations[$i][0] =~ /mnt/) {

                    my @arr = split(/_/,$addressLocations[$i][0]);
                    for my $j (0 .. $#arr) {
                      #print $arr[$j]."\n";
                      if ($arr[$j] =~ /mnt/) {

                          #logMsg($LOG_INFO,"identified correct mount node");
                          $mountNode = $arr[$j];
                          last;
                      }

                    }

                }

                if ($addressLocations[$i][0] =~ m/node/) {
                    my @arr = split(/_/,$addressLocations[$i][0]);
                    for my $j (0 .. $#arr) {
                      if ($arr[$j] =~ /node/) {
                          $mountNode = $arr[$j];
                          last;
                      }
                  }
                }
                if ($addressLocations[$i][0] =~ "data") {

                    logMsg($LOG_INFO,$addressLocations[$i][1].":/".$addressLocations[$i][0]."   /hana/data/".$strHANASID."/".$mountNode."   ".$strMountOptions);

                }
                if ($addressLocations[$i][0] =~ "log" and $addressLocations[$i][0] !~ "dp") {

                    logMsg($LOG_INFO,$addressLocations[$i][1].":/".$addressLocations[$i][0]."   /hana/log/".$strHANASID."/".$mountNode."   ".$strMountOptions);

                }
                if ($addressLocations[$i][0] =~ "shared") {

                    for my $j (0 .. $#qtreeLocations) {
                        if ($qtreeLocations[$j] =~ "shared") {
                          logMsg($LOG_INFO,$addressLocations[$i][1].":/".$addressLocations[$i][0]."/".$qtreeLocations[$j]."   /hana/shared/".$strHANASID."   ".$strMountOptions);
                        } else {
                          logMsg($LOG_INFO,$addressLocations[$i][1].":/".$addressLocations[$i][0]."/".$qtreeLocations[$j]."   /usr/sap/".$strHANASID."   ".$strMountOptions);
                        }
                    }
                }
                if ($addressLocations[$i][0] =~ "log_backups") {

                    logMsg($LOG_INFO,$addressLocations[$i][1].":/".$addressLocations[$i][0]."   /hana/logbackups/".$strHANASID."   ".$strMountOptions);
                }

     }

}

sub displayArray
{

print color('bold cyan');
logMsg($LOG_INFO, "**********************Displaying Snapshots by Volume*****+*****************");
print color('reset');
         for my $i (0 .. $#snapshotLocations) {
                my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref} ) {

                         logMsg($LOG_INFO,$snapshotLocations[$i][$j]);

                }
         }

}

sub displaySnapshotArray
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Displaying Snapshot Details by Volume**********************");
print color('reset');


            for my $i (0 .. $#snapshotLocations) {
              my $displayVolume = 0;
              my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref} ) {
                      logMsg($LOG_INFO,$snapshotLocations[$i][$j]);


                  }
              }


}


sub displaySnapmirrorVolumesArray
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Displaying Relationships by Volume**********************");
print color('reset');
         for my $i (0 .. $#replicationList) {


                         logMsg($LOG_INFO,$replicationList[$i]);

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
my $inputProceed;
my $strHello = "This script is designed for those customers who have previously installed the Production HANA instance in the Disaster Recovery Location either as a stand-alone instance or as part of a multi-purpose environment. This script should only be run in the event of a declared disaster by Microsoft or as part of required Disaster Recovery testing plans. A failback coordinated with Microsoft Operations is required after this script has been executed.  WARNING: the failback process will not necessarily be a quick process and will require multiple steps in coordination with Microsoft Operations so this script should not be undertaken lightly.  This script will restore only the most recent snapshot for both the Data and Log Backups filesystems.  Any other restore points must be handled by Microsoft Operations.  Please enter the HANA <SID> you wish to restore. This script must be executed from the Disaster Recovery location otherwise unintended actions may occur.\n";
$strHello =~ s/([^\n]{0,120})(?:\b\s*|\n)/$1\n/gio;
print $strHello;
push (@arrOutputLines, $strHello);
do {
  print "Please enter (yes/no):  ";
  $inputProceed = <STDIN>;
  $inputProceed =~ s/[\n\r\f\t]//g;
  if ($inputProceed =~ m/no/i) {
    exit;
  }
} while ($inputProceed !~ m/yes/i);
#logMsg( $LOG_INPUT, "Please enter either the HANA Instance you wish to restore:" );
my $strHANAInstanceInput = "Please enter either the HANA Instance you wish to restore:   ";
print $strHANAInstanceInput;
push (@arrOutputLines, $strHANAInstanceInput);
my $inputHANAInstance = <STDIN>;
$inputHANAInstance =~ s/[\n\r\f\t]//g;
$strHANAInstance = lc $inputHANAInstance;



#read and store each line of HANABackupCustomerDetails to fileHandle
runOpenParametersFiles();

#verify each line is expected based on template, otherwise throw error.
runVerifyParametersFile();

#add Parameters to usable array customerDetails
runGetParameterDetails();

#verify all required details entered for each SID
runVerifySIDDetails();


my $i = 0;
while ($arrCustomerDetails[$i][0] ne $strHANAInstance) {

  if ($i eq $numSID) {

      logMsg($LOG_WARN, "The Entered SID was not found within the HANABackupCustomerDetails.txt file.  Please double-check that file.");
      print color('bold red');
      runExit( $ERR_WARN );

    }
    if ($arrCustomerDetails[$i][0] eq $strHANAInstance) {
      last;
    }
    $i++;
}


#print $arrCustomerDetails[$i][0];
$strUser = $arrCustomerDetails[$i][1];
$strSVM = $arrCustomerDetails[$i][2];
# get volume(s) to take a snapshot of
runGetVolumeLocations();

#get Qtree locations for shared volume
runGetQtreeLocations();

#get snapshots by volume and place into array
runGetSnapshotsByVolume();
displayArray();

#verify either HANA Backup ID or snapshot name is found
runVerifySnapshotsExist();

#get SnapMirror relationships
runGetSnapmirrorRelationships();
displaySnapmirrorVolumesArray();

#updates SnapMirror relationships
runUpdateSnapMirror();

#Quiesces SnapMirror relationships
runQuiesceSnapMirror();

#break SnapMirror relationships
runBreakSnapMirror();

#restores snapshots
runRestoreSnapshot();

#mounts DR volumes to namespace
runMountDRVolumes();

#displays mount points of DR volumes
runDisplayMountPoints();


runPrintFile();
# time to exit
runExit( $ERR_NONE );
