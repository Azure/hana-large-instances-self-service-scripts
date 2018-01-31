#!/usr/bin/perl -w
#
# Copyright (C) 2017 Accenture, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: testStorageSnapshotConnection.pl
# Version: 3.0
# Date 01/27/2018

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Term::ANSIColor;
#Usage:  This script is used to test a customer's connection to the underlying storage virtual machine to ensure it is working correctly before attemping to run any other scripts that perform storage snapshots.
#

#number of allowable SIDs. Number entered is one less than actual.. i.e if allowing 4 SIDs, then 3 is entered
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

my $verbose = 1;
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
my @arrCustomerDetails;
my @fileLines;
my @strSnapSplit;
my $strHANAServerName;
my $strHANAServerIPAddress;
my $filename = "HANABackupCustomerDetails.txt";
my $sshCmd = '/usr/bin/ssh';

my $strUser;
my $strSVM;

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

#DO NOT MODIFY THESE VARIABLES!!!!

my $strStorageSnapshotStatusCmd = "volume show -type RW -fields volume";
my $outputFilename = "";
my $strHANAInstance;
my @volLocations;
my @snapshotLocations;
my $strSnapshotPrefix = "testStorage";



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
  #logMsg($LOG_INFO,"$sshCmd -l $strUser $strSVM");
  return(  `"$sshCmd" -l $strUser $strSVM 'set -showseparator ","; $strShellCmd' 2>&1` );
#	return(  `"$sshCmd" -l $strUser $strSVM 'set -showseparator ","; $strShellCmd' 2>&1` );
}

#
# Name: runCheckHANAStatus()
# Func: Create the HANA snapshot
#
sub runCheckStorageSnapshotStatus
{
      print color('bold cyan');
      logMsg($LOG_INFO, "**********************Checking access to Storage**********************");
      print color('reset');
      # Create a HANA database snapshot via HDBuserstore, key snapper
			my @out = runSSHCmd( $strStorageSnapshotStatusCmd );
			if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "Storage check status command '" . $strStorageSnapshotStatusCmd . "' failed: $?" );
          logMsg( $LOG_WARN, "Please check the following:");
          logMsg( $LOG_WARN, "Was publickey sent to Microsoft Service Team?");
          logMsg( $LOG_WARN, "If passphrase entered while using ssh-keygen, publickey must be re-created and passphrase must be left blank for both entries");
          logMsg( $LOG_WARN, "Ensure correct IP address was entered in HANABackupCustomerDetails.txt");
          logMsg( $LOG_WARN, "Ensure correct Storage backup name was entered in HANABackupCustomerDetails.txt");
          logMsg( $LOG_WARN, "Ensure that no modification in format HANABackupCustomerDetails.txt like additional lines, line numbers or spacing");
					logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
					exit;
				} else {
          print color('bold green');
          logMsg( $LOG_INFO, "Storage Access successful!!!!!!!!!!!!!!" );
          print color('reset');
      }

}

sub runGetVolumeLocations
{
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Getting list of volumes that match HANA instance specified**********************");
  print color('reset');
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
				$snapshotLocations[$i][0] = $name;

			}
	$i++;
	}
}



sub runCreateStorageSnapshot
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Creating Storage snapshot**********************");
print color('reset');
		for my $i (0 .. $#snapshotLocations) {
		# take the recent snapshot with SSH
		logMsg( $LOG_INFO, "Taking snapshot $strSnapshotPrefix\.temp for $snapshotLocations[$i][0] ..." );
#storage command necessary to create storage snapshot, others items to include: snapmirror-label matching snapshot type/frequency and HANA snapshot backup id matching as comment
		my $date = localtime->strftime('%Y-%m-%d_%H%M');
		my $strSSHCmd = "volume snapshot create -volume $snapshotLocations[$i][0] -snapshot $strSnapshotPrefix\.$date\.temp -snapmirror-label $strSnapshotPrefix";
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
print color('bold cyan');
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
print color('reset');
		my $i = 0;

		logMsg( $LOG_INFO, "Collecting set of snapshots for each volume hosting HANA matching pattern *$strHANAInstance* ..." );
		for my $i (0 .. $#snapshotLocations) {
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

		}

}

sub displayArray
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Displaying Snapshots by Volume**********************");
print color('reset');
         for my $i (0 .. $#snapshotLocations) {
                my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref} ) {

                         logMsg($LOG_INFO,$snapshotLocations[$i][$j]);
                 }
         }

}

sub runClearVolumeLocations
{
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Clearing volume list**********************");
  print color('reset');
  undef @volLocations;
}

sub runClearSnapshotLocations
{
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Clearing snapshot list**********************");
  print color('reset');
  undef @snapshotLocations;
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
     logMsg($LOG_INFO, "Checking Snapshot Status for $strHANAInstance");
     print color('reset');
     $strUser = $arrCustomerDetails[$i][1];
     $strSVM = $arrCustomerDetails[$i][2];

  } else {
    logMsg($LOG_INFO, "No data entered for SID".($i+1)."  Skipping!!!");
    next;
  }

# execute the check access command
runCheckStorageSnapshotStatus();

# get volume(s) to take a snapshot of based on HANA instance provided
runGetVolumeLocations();

# execute a storage snapshot of empty volume to create values
runCreateStorageSnapshot();
runGetSnapshotsByVolume();
displayArray();

runClearSnapshotLocations();
runClearVolumeLocations();

}
# if we get this far, we can exit cleanly
runPrintFile();
# time to exit
runExit( $ERR_NONE );