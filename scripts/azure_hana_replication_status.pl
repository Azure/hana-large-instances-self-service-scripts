#!/usr/bin/perl -w
#
# Copyright (C) 2017 Microsoft, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: azure_hana_backup.pl
#Version: 3.0
#Date 01/27/2018

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Term::ANSIColor;
#Usage:  This script is used to test a customer's connection to the HANA database to ensure it is working correctly before attemping to run the script.
#
my $numSID = 9;
my $detailsStart = 13;
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
my @arrCustomerDetails;
my @snapshotRestorationList;
my @replicationList;
my $strHANABackupID;
my $strHANAInstance;
my $inputRestoration;
my $inputTypeRestoration;
my $logBackupsVolume;
my $logBackupsSnapshot;
my @snapMirrorLocations;
my $strHANAServerName;
my $strHANAServerIPAddress;
my $filename = "HANABackupCustomerDetails.txt";

my $strUser;
my $strSVM;

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


#DO NOT MODIFY THESE VARIABLES!!!!
my $sshCmd = '/usr/bin/ssh';
my $verbose = 1;

my $arrSnapshot = "";
my $outputFilename = "";


# Global parameters
my @snapshotLocations;
my @snapshotDetails;
my @volLocations;

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
  print color('bold green');
  logMsg($LOG_INFO, "**********************Getting list of replication relationships that match HANA instance provided**********************");
	logMsg( $LOG_INFO, "Collecting set of relationships hosting HANA matching pattern *$strHANAInstance* ..." );
  print color('reset');
#  my $strSSHCmd = "snapmirror show -destination-volume *dp* -destination-volume *".$strHANAInstance."* -fields destination-volume, status, state, lag-time, last-transfer-size";
  my $strSSHCmd = "snapmirror show -type dp -destination-volume *".$strHANAInstance."* -fields destination-volume, status, state, lag-time, last-transfer-size";
  my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
    print color('bold yellow');
    logMsg( $LOG_INFO, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_INFO, "Retrieving replication relationships failed.  Please check to make sure that $strHANAInstance is the correct HANA instance and has a DR Relationship.  Otherwise, please contact MS Operations for assistance with Disaster Recovery setup.");
    print color('reset');
  } else {
    print color('bold green');
    logMsg( $LOG_INFO, "Relationship show completed successfully." );
    print color('reset');
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
print color('bold blue');
logMsg($LOG_INFO, "**********************Displaying Relationships by Volume**********************");
print color('reset');
         for my $i (0 .. $#snapMirrorLocations) {

                    if ($snapMirrorLocations[$i][0] =~ /data/) {

                         print color('bold green');
                         logMsg($LOG_INFO,$snapMirrorLocations[$i][0]);
                         print color('reset');
                         print color('bold cyan');
                         logMsg($LOG_INFO,"-------------------------------------------------");
                         print color('reset');
                         if ($snapMirrorLocations[$i][1] =~ /Broken-off/) {
                           logMsg($LOG_INFO,"Link Status: Broken-Off");
                         } else {
                           logMsg($LOG_INFO,"Link Status: Active");
                         }
                         logMsg($LOG_INFO,"Current Replication Activity: ".$snapMirrorLocations[$i][2]);
                         logMsg($LOG_INFO,"Latest Snapshot Replicated: ".$snapMirrorLocations[$i][3]);
                         logMsg($LOG_INFO,"Size of Latest Snapshot Replicated: ".$snapMirrorLocations[$i][4]);
                         logMsg($LOG_INFO,"Current Lag Time between snapshots: ".$snapMirrorLocations[$i][5]. "   ***Less than 30 minutes is recommended***");
                         logMsg($LOG_INFO,"*************************************************");

                    }
                    if ($snapMirrorLocations[$i][0] =~ /log/) {

                         print color('bold green');
                         logMsg($LOG_INFO,$snapMirrorLocations[$i][0]);
                         print color('reset');
                         print color('bold cyan');
                         logMsg($LOG_INFO,"-------------------------------------------------");
                         print color('reset');
                         if ($snapMirrorLocations[$i][1] =~ /Broken-off/) {
                           logMsg($LOG_INFO,"Link Status: Broken-Off");
                         } else {
                           logMsg($LOG_INFO,"Link Status: Active");
                         }
                         logMsg($LOG_INFO,"Current Replication Activity: ".$snapMirrorLocations[$i][2]);
                         logMsg($LOG_INFO,"Latest Snapshot Replicated: ".$snapMirrorLocations[$i][3]);
                         logMsg($LOG_INFO,"Size of Latest Snapshot Replicated: ".$snapMirrorLocations[$i][4]);
                         logMsg($LOG_INFO,"Current Lag Time between snapshots: ".$snapMirrorLocations[$i][5]. "   ***Less than 10 minutes is recommended***");
                         logMsg($LOG_INFO,"*************************************************");

                    }
                    if ($snapMirrorLocations[$i][0] =~ /shared/) {

                         print color('bold green');
                         logMsg($LOG_INFO,$snapMirrorLocations[$i][0]);
                         print color('reset');
                         print color('bold cyan');
                         logMsg($LOG_INFO,"-------------------------------------------------");
                         print color('reset');
                         if ($snapMirrorLocations[$i][1] =~ /Broken-off/) {
                           logMsg($LOG_INFO,"Link Status: Broken-Off");
                         } else {
                           logMsg($LOG_INFO,"Link Status: Active");
                         }
                         logMsg($LOG_INFO,"Current Replication Activity: ".$snapMirrorLocations[$i][2]);
                         logMsg($LOG_INFO,"Latest Snapshot Replicated: ".$snapMirrorLocations[$i][3]);
                         logMsg($LOG_INFO,"Size of Latest Snapshot Replicated: ".$snapMirrorLocations[$i][4]);
                         logMsg($LOG_INFO,"Current Lag Time between snapshots: ".$snapMirrorLocations[$i][5]. "   ***Less than 30 minutes is recommended***");
                         logMsg($LOG_INFO,"*************************************************");
                    }
          }
}

sub runClearSnapMirrorRelationships {

  undef @snapMirrorLocations;

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
#read and store each line of HANABackupCustomerDetails to fileHandle
runOpenParametersFiles();

#verify each line is expected based on template, otherwise throw error.
runVerifyParametersFile();

#add Parameters to usable array customerDetails
runGetParameterDetails();

#verify all required details entered for each SID
runVerifySIDDetails();

for my $i (0 .. $numSID) {

  #logMsg($LOG_INFO,"arrCustomerDetails[".$i."][0]: ". $arrCustomerDetails[$i][0]);
  if ($arrCustomerDetails[$i][0] and ($arrCustomerDetails[$i][0] ne "Skipped" and $arrCustomerDetails[$i][0] ne "Omitted")) {
     $strHANAInstance = $arrCustomerDetails[$i][0];
     print color('bold blue');
     logMsg($LOG_INFO, "Checking Relationship Status for $strHANAInstance");
     print color('reset');
     $strUser = $arrCustomerDetails[$i][1];
     $strSVM = $arrCustomerDetails[$i][2];

  } else {
    logMsg($LOG_INFO, "No data entered for SID".($i+1)."  Skipping!!!");
    next;
  }

  # get volume(s) to take a snapshot of
  runGetSnapmirrorRelationships();
  displayArray();

  runClearSnapMirrorRelationships();
}



# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
