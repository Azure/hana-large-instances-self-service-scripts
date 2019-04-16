#!/usr/bin/perl -w
#
# Copyright (C) 2017 Microsoft, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: azure_hana_test_dr_failover.pl
#Version: 3.3
#Date 05/15/2018

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Time::HiRes;
use Term::ANSIColor;
#number of allowable SIDs. Number entered is one less than actual.. i.e if allowing 4 SIDs, then 3 is entered
my $numSID = 9;
my $detailsStart = 11;
#Usage:  This script is intended to allow customers to to test the automatic failover of their Production instance from their Production location to
#their Disaster Recovery location.  The script does not break the SnapMirror relationship between the two locations. Instead the script creates a clone of the Snapmirrored volumes in the DR site and provides the mount point details for the DR build.
#
# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE=0;
my $ERR_WARN=1;

# Log levels -- LOG_INFO, LOG_CRIT, LOG_WARN, LOG_INPUT.  Bitmap values
my $LOG_INFO=1; #standard output to file or displayed during verbose
my $LOG_CRIT=2; #displays only critical output to console and log file
my $LOG_WARN=3; #displays any warnings to console and log file
my $LOG_INPUT=4; #displays output to both console and file always, does not include new line command at end of output.
# Global parameters

my $exitWarn = 0;
my $exitCode;

my $verbose = 0;


#
# Global Tunables
#

my $date = localtime->strftime('%Y%m%d_%H%M');
my $version = "3.3";  #current version number of script
my @arrOutputLines;                   #Keeps track of all messages (Info, Critical, and Warnings) for output to log file
my @fileLines;                        #Input stream from HANABackupCustomerDetails.txt
my @strSnapSplit;
my @arrClones;
my @arrCustomerDetails;               #array that keeps track of all inputs on the HANABackupCustomerDetails.txt
my @volLocations;                     #array of all volumes that match SID input by customer
my @replicationList;                  #array of all replication relationships between production and DR
my @addressLocations;                 #array of all necessary volumes and subvolumes for restoration and their IP addresses
my @qtreeLocations;                   #array of subvolumes for shared volume
my @snapshotLocations;                #array that keeps track of restorable Snapshots
my @snapshotCloneList;                #array that keeps track of volumes that require cloning
my @dataCloneList;
my @logBackupsList;                   #array that keeps track of log backups volumes that require restoring
my @displayMounts;                    #keeps track of mount points to display
my $strPrimaryHANAServerName;         #Customer provided IP Address or Qualified Name of Primay HANA Server.
my $strPrimaryHANAServerIPAddress;    #Customer provided IP address of Primary HANA Server
my $strSecondaryHANAServerName;       #Customer provided IP Address or Qualified Name of Seconary HANA Server.
my $strSecondaryHANAServerIPAddress;  #Customer provided IP address of Secondary HANA Server
my $filename = "HANABackupCustomerDetails.txt";
my $strUser;                          #Microsoft Operations provided storage user name for backup access
my $strSVM;                           #IP address of storage client for backup
my $sshCmd = '/usr/bin/ssh';          #typical location of ssh on SID
my $strHANASID;                       #The customer entered HANA SID for each iteration of SID entered with HANABackupCustomerDetails.txt
my $outputFilename = "";              #Generated filename for scipt output

my $logBackupsVolume;                 #name of log backups volume required for restoration
my $logBackupsSnapshot;               #name of snapshot with index 0 for log backups volume
my $HSR = 0;                          #flags whether HSR is detected in environment

#
# Name: runOpenParametersFiles
# Func: open the customer-based text file to gather required details
#

sub runOpenParametersFiles {
  open(my $fh, '<:encoding(UTF-8)', $filename)
    or die "Could not open file '$filename' $!";

  chomp (@fileLines=<$fh>);
  close $fh;
}

#
# Name: runVerifyParametersFile
# Func: verifies HANABackupCustomerDetails.txt input file adheres to expected format
#

sub runVerifyParametersFile {

  my $k = $detailsStart;
  my $lineNum;
  $lineNum = $k-3;
  my $strServerName = "HANA Server Name:";
  if ($fileLines[$lineNum-1]) {
    if (index($fileLines[$lineNum-1],$strServerName) eq -1) {
      logMsg($LOG_WARN, "Expected ".$strServerName);
      logMsg($LOG_WARN, "Verify line ".$lineNum." is for the HANA Server Name. Exiting");
      runExit($exitWarn);
    }
  }


  $lineNum = $k-2;
  my $strHANAIPAddress = "HANA Server IP Address:";
  if ($fileLines[$lineNum-1]) {
    if (index($fileLines[$lineNum-1],$strHANAIPAddress) eq -1  ) {
      logMsg($LOG_WARN, "Expected ".$strHANAIPAddress);
      logMsg($LOG_WARN, "Verify line ".$lineNum." is the HANA Server IP Address. Exiting");
      runExit($exitWarn);
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
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string2 = "SID".($i+1);
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string2) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string2);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is for SID #$i. Exiting");
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string3 = "###Provided by Microsoft Operations###";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string3) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string3);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting");
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string4 = "SID".($i+1)." Storage Backup Name:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string4) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string4);
            logMsg($LOG_WARN, "Verify line ".$lineNum." contains the storage backup as provied by Microsoft Operations. Exiting.");
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string5 = "SID".($i+1)." Storage IP Address:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string5) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string5);
            logMsg($LOG_WARN, "Verify line ".$lineNum." contains the Storage IP Address. Exiting.");
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string6 = "######     Customer Provided    ######";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string6) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string6);
            logMsg($LOG_WARN, "Verify line ".$lineNum." is correct. Exiting.");
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string7 = "SID".($i+1)." HANA instance number:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string7) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string7);
            logMsg($LOG_WARN, "Verify line ".$lineNum." contains the HANA instance number. Exiting.");
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        my $string8 = "SID".($i+1)." HANA HDBuserstore Name:";
        if ($fileLines[$lineNum-1]) {
          if (index($fileLines[$lineNum-1],$string8) eq -1) {
            logMsg($LOG_WARN, "Expected ". $string8);
            logMsg($LOG_WARN, "Verify line ".$lineNum." contains the HDBuserstore Name. Exiting.");
            runExit($exitWarn);
          }
        }
        $j++;
        $lineNum = $k+$j;
        if ($#fileLines >= $lineNum-1 and $fileLines[$lineNum-1]) {
          if ($fileLines[$lineNum-1] ne "") {
            logMsg($LOG_WARN, "Expected Blank Line");
            logMsg($LOG_WARN, "Verify line ".$lineNum." is blank. Exiting.");
            runExit($exitWarn);
            }
          }
      }
}

#
# Name: runGetParameterDetails
# Func: after verifying HANABackupCustomerDetails, it is now interpreted into usable format
#

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
    $strPrimaryHANAServerName = $strSnapSplit[1];
    logMsg($LOG_CRIT,"HANA Server Name: ".$strPrimaryHANAServerName);
  }

  undef @strSnapSplit;
  #HANA SERVER IP Address
  $lineNum = $k-2;
  if (substr($fileLines[$lineNum-1],0,1) ne "#") {
    @strSnapSplit = split(/:/, $fileLines[$lineNum-1]);
  } else {
    logMsg($LOG_WARN,"Cannot skip HANA Server IP Address. It is a required field");
    runExit($exitWarn);
  }
  if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
    $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
    $strPrimaryHANAServerIPAddress = $strSnapSplit[1];
    logMsg($LOG_CRIT,"HANA Server IP Address: ".$strPrimaryHANAServerIPAddress);
  }

  #run through each SID up to number allowed in $numSID
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
      logMsg($LOG_CRIT,"SID".($i+1).": ".$arrCustomerDetails[$i][0]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][0] = lc $strSnapSplit[1];
      logMsg($LOG_CRIT,"SID".($i+1).": ".$arrCustomerDetails[$i][0]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][0]) {
            $arrCustomerDetails[$i][0] = "Omitted";
            logMsg($LOG_CRIT,"SID".($i+1).": ".$arrCustomerDetails[$i][0]);

    }

    #Storage Backup Name
    if (substr($fileLines[$j+2],0,1) ne "#") {
    @strSnapSplit = split(/:/, $fileLines[$j+2]);
    } else {
      $arrCustomerDetails[$i][1] = "Skipped";
      logMsg($LOG_CRIT,"Storage Backup Name: ".$arrCustomerDetails[$i][1]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][1] = lc $strSnapSplit[1];
      logMsg($LOG_CRIT,"Storage Backup Name: ".$arrCustomerDetails[$i][1]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][1]) {
            $arrCustomerDetails[$i][1] = "Omitted";
            logMsg($LOG_CRIT,"Storage Backup Name: ".$arrCustomerDetails[$i][1]);

    }

    #Storage IP Address
    if (substr($fileLines[$j+3],0,1) ne "#") {
      @strSnapSplit = split(/:/, $fileLines[$j+3]);
    } else {
      $arrCustomerDetails[$i][2] = "Skipped";
      logMsg($LOG_CRIT,"Storage Backup Name: ".$arrCustomerDetails[$i][2]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][2] = $strSnapSplit[1];
      logMsg($LOG_CRIT,"Storage IP Address: ".$arrCustomerDetails[$i][2]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][2]) {
            $arrCustomerDetails[$i][2] = "Omitted";
            logMsg($LOG_CRIT,"Storage Backup Name: ".$arrCustomerDetails[$i][2]);

    }

    #HANA Instance Number
    if (substr($fileLines[$j+5],0,1) ne "#") {
      @strSnapSplit = split(/:/, $fileLines[$j+5]);
    } else {
      $arrCustomerDetails[$i][3] = "Skipped";
      logMsg($LOG_CRIT,"HANA Instance Number: ".$arrCustomerDetails[$i][3]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][3] = $strSnapSplit[1];
      logMsg($LOG_CRIT,"HANA Instance Number: ".$arrCustomerDetails[$i][3]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][3]) {
            $arrCustomerDetails[$i][3] = "Omitted";
            logMsg($LOG_CRIT,"HANA Instance Number: ".$arrCustomerDetails[$i][3]);

    }

    #HANA User name
    if (substr($fileLines[$j+6],0,1) ne "#") {
      @strSnapSplit = split(/:/, $fileLines[$j+6]);
    } else {
      $arrCustomerDetails[$i][4] = "Skipped";
      logMsg($LOG_CRIT,"HANA Instance Number: ".$arrCustomerDetails[$i][4]);
    }
    if ($strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/) {
      $strSnapSplit[1]  =~ s/^\s+|\s+$//g;
      $arrCustomerDetails[$i][4] = uc $strSnapSplit[1];
      logMsg($LOG_CRIT,"HANA Userstore Name: ".$arrCustomerDetails[$i][4]);
    } elsif (!$strSnapSplit[1] and !$arrCustomerDetails[$i][4]) {
            $arrCustomerDetails[$i][4] = "Omitted";
            logMsg($LOG_CRIT,"HANA Instance Number: ".$arrCustomerDetails[$i][4]);

    }
  }
}

#
# Name: runVerifySIDDetails
# Func: ensures that all necessary details for an SID entered are provided and understood.
#

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
            runExit($exitWarn);
        }
    }
}


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
  #$LOG_INFO
  if ( $errValue eq 1) {
		$str .= "$msgString";
		$str .= "\n";
    if ($verbose eq 1) {
      print $str;
    }
    push (@arrOutputLines, $str);
	}
  #$LOG_CRIT
  if ( $errValue eq 2 ) {
    $str .= "$msgString";
    $str .= "\n";
    print $str;
    push (@arrOutputLines, $str);
  }

  #$LOG_WARN
	if ( $errValue eq 3 ) {
		$str .= "WARNING: $msgString\n";
		$exitWarn = 1;
    print color('bold red');
    print "$str\n";
    print color('reset');
    push (@arrOutputLines, $str);
  }

  #$LOG_INPUT
  if ( $errValue eq 4 ) {
    $str .= "$msgString";
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
		logMsg( $LOG_CRIT, "Exiting with return code: $exitCode" );
    if ($exitCode eq 0) {

      print color ('bold green');
      logMsg( $LOG_CRIT, "Command completed successfully." );
      print color ('reset');
    }
    if ($exitCode eq 1) {

      print color ('bold red');
      logMsg( $LOG_CRIT, "Command failed. Please check screen output or created logs for errors." );
      print color ('reset');
    }


  }
  runPrintFile();
	# exit with our error code
	exit( $exitCode );
}


#
# Name: runShellCmd
# Func: Run a command in the shell and return the results.
#
sub runShellCmd
{
	my ( $strShellCmd ) = @_;
	return( `$strShellCmd 2>&1` );
}

#
# Name: runSSHCmd
# Func: Run an SSH command.
#

sub runSSHCmd
{
	my ( $strShellCmd ) = @_;
	return(  `"$sshCmd" -l $strUser $strSVM 'set -showseparator ","; $strShellCmd' 2>&1` );
}

sub runSSHDiagCmd
{
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
  logMsg($LOG_CRIT, "**********************Getting list of volumes that match HANA instance specified**********************");
  print color('reset');
  logMsg( $LOG_CRIT, "Collecting set of volumes hosting HANA matching pattern *$strHANASID* ..." );
  my $strSSHCmd = "volume show -volume *".$strHANASID."* -volume !*clone* -state online -fields volume";
  my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Retrieving volumes failed.  Please check to make sure that $strHANASID is the correct HANA instance.");
    logMsg( $LOG_WARN, "Additionally, please verify script is executed from Disaster Recovery location.");
    logMsg( $LOG_WARN, "Otherwise, please contact Microsoft Operations for assistance");
    runExit($exitWarn);
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
			if (defined $name) {
				logMsg( $LOG_CRIT, "Adding volume $name to the snapshot list." );
				push( @volLocations, $name);
        if ($name !~ m/data/ and $name !~ m/log_backups/) {
            push( @displayMounts, $name);
        }
      }
	$i++;
	}
}

#
# Name: runGetQtreeLocations
# Func: get the list of subvolumes for shared volume
#

sub runGetQtreeLocations
{
  print color('bold cyan');
  logMsg($LOG_CRIT, "**********************Getting list of Qtrees of shared volume**********************");
  print color('reset');
  foreach my $volName ( @volLocations ) {

    if ($volName =~ "shared" and $volName =~ "vol") {


    logMsg( $LOG_CRIT, "Collecting set of qtrees for $volName ..." );
    my $strSSHCmd = "qtree show -volume ".$volName." -fields qtree";
    my @out = runSSHCmd( $strSSHCmd );
  	if ( $? ne 0 ) {
  		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
      logMsg( $LOG_WARN, "Retrieving sub-volumes failed.  Please check to make sure that $strHANASID is the correct HANA instance.  Otherwise, please contact MS Operations for assistance with Disaster Recovery failover.");
      runExit($exitWarn);
    } else {
  		logMsg( $LOG_CRIT, "Subvolume show completed successfully." );
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
  			if (defined $name) {
          if ($name ne '""') {
            logMsg( $LOG_CRIT, "Adding qtree $name to the qtree list." );
  				  push( @qtreeLocations, $name);
          }
  			}
  	 $i++;
  	 }
   }
 }
}

#
# Name: runGetSnapshotsByVolume
# Func: Get the list of snapshots on a per volume basis
#

sub runGetSnapshotsByVolume
{
print color('bold cyan');
logMsg($LOG_CRIT, "**********************Adding list of snapshots to volume list**********************");
print color('reset');
		my $i = 0;
    logMsg( $LOG_INFO, "Collecting set of snapshots for each volume hosting HANA matching pattern *$strHANASID* ..." );
		foreach my $volName ( @volLocations ) {
				my $j = 0;

        if ((($volName !~ /data/ and $volName !~ /log_backups/) and ($volName =~ /dp/ or $volName =~ /xdp/)) or $volName =~ /vol/)  {
          next;
        }
        $snapshotLocations[$i][0] = $volName;
        my $strSSHDiagCmd = "snapshot show -volume $volName -snapshot !*snapmirror* -sort-by create-time -snapmirror-label hourly|3min|5min|15min -fields snapshot";
        my @out = runSSHDiagCmd( $strSSHDiagCmd );
				if ( $? ne 0 ) {
          print color('bold red');
          logMsg( $LOG_CRIT, "WARNING: Running '" . $strSSHDiagCmd . "' failed: $?" );
          logMsg( $LOG_CRIT, "WARNING: No snapshots were found for volume: $volName.  Please verify you have provided the correct HANA instance.");
          logMsg( $LOG_CRIT, "WARNING: If $volName is not part of an HSR node, please contact Microsoft Operations for assistance.");
          print color('reset');
          print color('bold green');
          logMsg( $LOG_CRIT, "NOTE: If $volName is part of an HSR node, then this is expected behavior. Please ignore and continue recovery.");
          print color('reset');
				}
				my $listnum = 0;
				$j=1;
				my $count = $#out-1;
				foreach my $k ( 0 ... $count ) {

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
# Name: runVerifySnapshotsExist
# Func: Verifies that each data volume has the correct snapshot of index 0 and that log backups volume has index of 0
#

sub runVerifySnapshotsExist
{
	 print color('bold cyan');
   logMsg($LOG_CRIT, "**********************Verifying correct number of snapshots exist for data volumes**********************");
   print color('reset');

   my $snapshotLogCount = 0;     #counts number of log backups snapshots found to compare to logCount
   my $logCount = 0;             #counts number of lob backups volumes that match SID
   my $snapshotFound = 0;        #identifies whether log backups snapshot with index 0 is found
   my $dataCount = 0;            #counts number of data volumes that match SID
   my $dataHSRCount = 0;         #used only for HSR builds to count number of data volumes
   my $snapshotCount = 0;        #counts number of snapshots with index 0 that are a member of data volumes

   logMsg( $LOG_CRIT, "Checking if latest snapshot name exists for HANA SID ".$strHANASID );
   my $mnt = "data_".$strHANASID."_mnt";
   for my $i (0 .. $#snapshotLocations) {
        my $volName = $snapshotLocations[$i][0];
        print color('bold cyan');
        logMsg($LOG_CRIT,"Volume: ".$volName);
        print color('reset');
        #handle one to many data volumes in non-HSR format
        if ($volName =~ /data/ and $volName =~ /$mnt/) {
            print color('bold magenta');
            logMsg($LOG_CRIT,"$volName is non-HSR volume");
            print color('reset');
            $dataCount++;
            logMsg($LOG_INFO,"Searching volume: ".$volName." for most recent snapshot");
            my $aref = $snapshotLocations[$i];
            my $j = $#{$aref};
            my $snapshotName = $snapshotLocations[$i][$j];
            logMsg($LOG_CRIT,"Snapshot: ".$snapshotName);

            $dataCloneList[$snapshotCount][0] = $volName;
            if ($snapshotName =~ /\.0/ or $snapshotName =~ /\.recent/ ) {
                $dataCloneList[$snapshotCount][1] = $snapshotName;
                $snapshotCount++;
            } else {
                $dataCloneList[$snapshotCount][1] = "";
            }
        }
        #handle the two data volumes in HSR
        if ($volName =~ /data/ and $volName !~ /$mnt/) {
            print color('bold magenta');
            logMsg($LOG_CRIT,"$volName is HSR volume");
            print color('reset');
            $HSR = 1;
            $dataHSRCount++;
            logMsg($LOG_INFO,"Searching volume: ".$volName." for most recent snapshot");
            my $aref = $snapshotLocations[$i];
            my $j = $#{$aref};
            my $snapshotName = $snapshotLocations[$i][$j];
            logMsg($LOG_CRIT,"Snapshot: ".$snapshotName);

            $dataCloneList[$snapshotCount][0] = $volName;
            if ($snapshotName =~ /\.0/ or $snapshotName =~ /\.recent/) {
                $dataCloneList[$snapshotCount][1] = $snapshotName;
                $snapshotCount++;
            } else {
                $dataCloneList[$snapshotCount][1] = "";
            }
        }

        #handle one or both logbackups volumes
        if ($volName =~ /log_backups/ ) {
            logMsg($LOG_INFO,"Searching volume: ".$volName." for expected latest snapshot .0");
            $logCount++;
            my $aref = $snapshotLocations[$i];
            my $j = $#{$aref};
            my $snapshotName = $snapshotLocations[$i][$j];
            logMsg($LOG_INFO,"Snapshot: ".$snapshotName);
            $logBackupsList[$snapshotLogCount][0] = $volName;
            if ($snapshotLocations[$i][$j] =~ /\.0/ or $snapshotLocations[$i][$j] =~ /\.recent/) {
                $logBackupsList[$snapshotLogCount][1] = $snapshotName;
                $snapshotLogCount++;
            }  else {
                $logBackupsList[$snapshotLogCount][1] = "";
            }
        }
    }
    #make sure non-HSR scale-up or scale-out have equal volumes to snapshot availability
    if ($snapshotCount eq $dataCount and $HSR eq 0) {
        print color('bold green');
        logMsg($LOG_CRIT,"All data volumes have correct snapshot present");
        print color('reset');

    } elsif ($HSR eq 0)  {
      logMsg($LOG_WARN,"Expected to match ".$dataCount." but found ".$snapshotCount." data volumes with correct snapshot");
      logMsg($LOG_WARN,"Please contact Microsoft Operations for assistance");
      runExit($exitWarn);
    }
  if ($HSR eq 1 and $dataHSRCount eq 2) {
      logMsg($LOG_CRIT,"Checking for most recent HSR data volume snapshot");
      my $volumeNode1 =  $dataCloneList[0][0];
      my $volumeNode2 =  $dataCloneList[1][0];
      my $snapshotNode1 =  $dataCloneList[0][1];
      my $snapshotNode2 =  $dataCloneList[1][1];
#      logMsg($LOG_CRIT, "Volume: $volumeNode1 Snapshot: $snapshotNode1");
#      logMsg($LOG_CRIT, "Volume: $volumeNode2 Snapshot: $snapshotNode2");

      if ($volumeNode1 eq "" and $volumeNode2 eq "" and $snapshotNode1 eq "" and $snapshotNode2 eq "") {
          logMsg($LOG_CRIT, "Volume: $volumeNode1 Snapshot: $snapshotNode1");
          logMsg($LOG_CRIT, "Volume: $volumeNode2 Snapshot: $snapshotNode2");
          my @strSnapSplitNode1 = split(/\./, $snapshotNode1);
          my @strSnapSplitNode2 = split(/\./, $snapshotNode2);
          my $node1date = $strSnapSplitNode1[1];
          my $node2date = $strSnapSplitNode2[1];
          logMsg($LOG_CRIT, "Date of Snapshot Node 1: $node1date");
          logMsg($LOG_CRIT, "Date of Snapshot Node 2: $node2date");

          my $node1t = Time::Piece->strptime($node1date, '%Y-%m-%d_%H%M');
          my $node2t = Time::Piece->strptime($node2date, '%Y-%m-%d_%H%M');
          my $tNode1Num = str2time($node1t);
          my $tNode2Num = str2time($node2t);
          if ($tNode1Num gt $tNode2Num) {
              print color('bold magenta');
              logMsg($LOG_CRIT, "Volume $volumeNode1 has the more recent snapshot.");
              print color('reset');
              my @tempArr;
              $tempArr[0][0] = $volumeNode1;
              $tempArr[0][1] = $snapshotNode1;
              push(@snapshotCloneList,@tempArr);

          } elsif ($tNode2Num gt $tNode1Num) {
              print color('bold magenta');
              logMsg($LOG_CRIT, "Volume $volumeNode2 has the more recent snapshot.");
              print color('reset');
              my @tempArr;
              $tempArr[0][0] = $volumeNode2;
              $tempArr[0][1] = $snapshotNode2;
              push(@snapshotCloneList,@tempArr);
          } else {
              logMsg($LOG_WARN, "Volume with most recent HSR cannot be determined.");
              logMsg($LOG_WARN, "Please contact Microsoft Operations for assistance.");
              runExit($exitWarn);
          }

          print color('bold green');
          logMsg($LOG_CRIT,"All data volumes have correct snapshot present");
          print color('reset');
      } else {
          logMsg($LOG_CRIT,"Not all volume and snapshots present.");
          logMsg($LOG_CRIT, "Volume: $volumeNode1 Snapshot: $snapshotNode1");
          logMsg($LOG_CRIT, "Volume: $volumeNode2 Snapshot: $snapshotNode2");
          if(($volumeNode1 eq "") or ($snapshotNode1 eq "")) {
              print color('bold magenta');
              logMsg($LOG_CRIT, "Volume $volumeNode1 does not contain most recent snapshot. Using $volumeNode2 for restore");
              print color('reset');
              my @tempArr;
              $tempArr[0][0] = $volumeNode2;
              $tempArr[0][1] = $snapshotNode2;
              push(@snapshotCloneList,@tempArr);
          } elsif (($volumeNode2 eq "") or ($snapshotNode2 eq "")) {
              print color('bold magenta');
              logMsg($LOG_CRIT, "Volume $volumeNode2 does not contain most recent snapshot. Using $volumeNode1 for restore");
              print color('reset');
              my @tempArr;
              $tempArr[0][0] = $volumeNode1;
              $tempArr[0][1] = $snapshotNode1;
              push(@snapshotCloneList,@tempArr);
          }
      }
  } else  {
      logMsg($LOG_WARN,"Expected to match two volumes but found ".$dataHSRCount." data volumes with snapshot for HSR");
      logMsg($LOG_WARN,"Please contact Microsoft Operations for assistance");
      runExit($exitWarn);
  }

  if ($snapshotLogCount eq $logCount and $HSR eq 0) {
      print color('bold green');
      logMsg($LOG_CRIT,"All log volumes have correct snapshot present");
      print color('reset');
  } elsif ($HSR eq 0) {
      logMsg($LOG_WARN,"Expected to match ".$logCount." but found ".$snapshotLogCount." log volumes with correct snapshot");
      logMsg($LOG_WARN,"Please contact Microsoft Operations for assistance");
      runExit($exitWarn);
  }

  if ($HSR eq 1 and $logCount eq 2) {
      logMsg($LOG_CRIT,"Checking for most recent HSR log backups volume snapshot");
      my $volumeNode1 =  $logBackupsList[0][0];
      my $volumeNode2 =  $logBackupsList[1][0];
      my $snapshotNode1 =  $logBackupsList[0][1];
      my $snapshotNode2 =  $logBackupsList[1][1];
      if ($volumeNode1 ne "" and $volumeNode2 ne "" and $snapshotNode1 ne "" and $snapshotNode2 ne "") {
          logMsg($LOG_CRIT, "Volume: $volumeNode1 Snapshot: $snapshotNode1");
          logMsg($LOG_CRIT, "Volume: $volumeNode2 Snapshot: $snapshotNode2");
          my @strSnapSplitNode1 = split(/\./, $snapshotNode1);
          my @strSnapSplitNode2 = split(/\./, $snapshotNode2);
          my $node1date = $strSnapSplitNode1[1];
          my $node2date = $strSnapSplitNode2[1];
          logMsg($LOG_CRIT, "Date of Snapshot Node 1: $node1date");
          logMsg($LOG_CRIT, "Date of Snapshot Node 2: $node2date");
          my $node1t = Time::Piece->strptime($node1date, '%Y-%m-%d_%H%M');
          my $node2t = Time::Piece->strptime($node2date, '%Y-%m-%d_%H%M');
          my $tNode1Num = str2time($node1t);
          my $tNode2Num = str2time($node2t);
          if ($tNode1Num gt $tNode2Num) {
              print color('bold magenta');
              logMsg($LOG_CRIT, "Volume $volumeNode1 has the more recent snapshot.");
              print color('reset');
              my @tempArr;
              $tempArr[0][0] = $volumeNode1;
              $tempArr[0][1] = $snapshotNode1;
              push(@snapshotCloneList,@tempArr);
          } elsif ($tNode2Num gt $tNode1Num) {
              print color('bold magenta');
              logMsg($LOG_CRIT, "Volume $volumeNode2 has the more recent snapshot.");
              print color('reset');
              my @tempArr;
              $tempArr[0][0] = $volumeNode2;
              $tempArr[0][1] = $snapshotNode2;
              push(@snapshotCloneList,@tempArr);
          } else {
              logMsg($LOG_WARN, "Volume with most recent HSR cannot be determined.");
              logMsg($LOG_WARN, "Please contact Microsoft Operations for assistance.");
              runExit($exitWarn);
          }
          print color('bold green');
          logMsg($LOG_CRIT,"All log backups volumes have correct snapshot present");
          print color('reset');
        } else {
            if($volumeNode1 eq "" or $snapshotNode1 eq "") {
                print color('bold magenta');
                logMsg($LOG_CRIT, "Volume $volumeNode1 does not contain most recent snapshot. Using $volumeNode2 for restore");
                print color('reset');
                my @tempArr;
                $tempArr[0][0] = $volumeNode2;
                $tempArr[0][1] = $snapshotNode2;
                push(@snapshotCloneList,@tempArr);
            } elsif ($volumeNode2 eq "" or $snapshotNode2 eq "") {
                print color('bold magenta');
                logMsg($LOG_CRIT, "Volume $volumeNode2 does not contain most recent snapshot. Using $volumeNode1 for restore");
                print color('reset');
                my @tempArr;
                $tempArr[0][0] = $volumeNode1;
                $tempArr[0][1] = $snapshotNode1;
                push(@snapshotCloneList,@tempArr);
              }

          }
      } else  {
          logMsg($LOG_WARN,"Expected to match two volumes but found ".$logCount." log backups volumes with snapshot for HSR");
          logMsg($LOG_WARN,"Please contact Microsoft Operations for assistance");
          runExit($exitWarn);
      }
}

#
# Name: runGetSnapmirrorVolumes
# Func: Gets the volume names of all active SnapMirror relationships that are part of SID
#

sub runGetSnapmirrorVolumes
{
  print color('bold cyan');
  logMsg($LOG_CRIT, "**********************Getting list of replication relationships that match HANA instance provided**********************");
  print color('reset');
  logMsg( $LOG_INFO, "Collecting set of relationships hosting HANA matching pattern *$strHANASID* ..." );
	my $strSSHCmd = "snapmirror show -type DP|XDP -destination-volume *$strHANASID* -destination-volume !*shared* -fields destination-volume";
	my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Retrieving replication relationships failed.");
    logMsg( $LOG_WARN, "Please check to make sure that $strHANASID is the correct HANA instance.");
    logMsg( $LOG_WARN, "Additionally, please make script is executed from Disaster Recovery location");
    logMsg( $LOG_WARN, "Otherwise, please contact Microsoft Operations for assistance.");
    runExit($exitWarn);
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
    if (defined $name) {
      logMsg( $LOG_CRIT, "Adding volume $name to the replication list." );
      $replicationList[$i] = $name;
			}
	$i++;
	}
}

#
# Name: runGetSnapmirrorRelationship
# Func: Gets the state and status of a single destination volume immediately preceding updating.
#

sub runGetSnapmirrorRelationship
{
  my $volName = shift;
  logMsg( $LOG_INFO, "Collecting set of relationships hosting HANA matching pattern *$strHANASID* ..." );
	my $strSSHCmd = "snapmirror show -destination-volume *$volName* -fields state,status";
	my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Retrieving replication relationships failed.");
    logMsg( $LOG_WARN, "Please check to make sure that $strHANASID is the correct HANA instance.");
    logMsg( $LOG_WARN, "Additionally, please make script is executed from Disaster Recovery location");
    logMsg( $LOG_WARN, "Otherwise, please contact Microsoft Operations for assistance.");
    runExit($exitWarn);
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

    my $state = $arr[$#arr-2];
    my $status = $arr[$#arr-1];

    if (defined $state and defined $status) {
      return($state,$status);
    } else {
      logMsg($LOG_WARN,"There was an error retrieving the current state for $volName.  Please try again in a few minutes");
      logMsg($LOG_WARN,"If the issue persists, please contact Microsoft Operations.");
      runExit($exitWarn);
    }
	}
}

#
# Name: runUpdateSnapMirrorRelationship
# Func: ensures that if replication link isn't broken, that all snapshots have been replicated to DR location for a single destination volume
#

sub runUpdateSnapMirror()
{
    print color('bold cyan');
    logMsg($LOG_CRIT, "**********************Updating Relationships by Volume**********************");
    print color('reset');
    for my $i (0 .. $#replicationList) {
          my $volName = $replicationList[$i];
          runUpdateSnapMirrorRelationship($volName);
    }
}

#
# Name: runUpdateSnapMirrorRelationship
# Func: ensures that if replication link isn't broken, that all snapshots have been replicated to DR location for a single destination volume
#

sub runUpdateSnapMirrorRelationship
{

    my $volName = shift;
    my ($state,$status) = runGetSnapmirrorRelationship($volName);

    if ($state eq "Snapmirrored") {
        if ($status eq "Quiescing" or $status eq "Quiesced") {
            next;
        }
        while ($status ne "Idle") {
            Time::HiRes::sleep (1+rand(2));
            logMsg($LOG_CRIT, "Volume $volName currently $status. Waiting until finished before updating.");
            my $strSSHCmd = "snapmirror show -destination-volume $volName -fields status";
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
                logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                logMsg( $LOG_WARN, "Retrieving replication relationship for $volName failed.");
                logMsg( $LOG_WARN, "Please contact MS Operations for assistance with Disaster Recovery failover.");
                runExit($exitWarn);
            } else {
                logMsg( $LOG_INFO, "Relationship show completed successfully." );
            }
            my $listnum = 0;
            my $count = $#out - 1;
            for my $j (0 ... $count ) {
                $listnum++;
                next if ( $listnum <= 3 );
                chop $out[$j];
                my @arr = split( /,/, $out[$j] );

                $status = $arr[$#arr-1];
            }
            logMsg($LOG_INFO, "Status of volume $volName is $status ");
        }

        if ($status eq "Idle") {
            my $strSSHCmd = "snapmirror update  -destination-volume ".$volName;
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
                logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                logMsg( $LOG_WARN, "The replication relationship for ".$volName." could not be updated.");
                logMsg( $LOG_WARN, "Please ensure you are executing this script from the Disaster Recovery location.");
                logMsg( $LOG_WARN, "If right location, Please wait a few minutes and try again.");
                logMsg( $LOG_WARN, "If issue persists, please contact Microsoft Operations");

                runExit($exitWarn);
            } else {
            		logMsg( $LOG_INFO, "Relationship updated for volume ".$volName." completed successfully." );
            }
        }
        $status = "Transferring";
        while ($status ne "Idle") {
            Time::HiRes::sleep (1+rand(2));
            logMsg($LOG_CRIT, "Volume $volName currently $status. Waiting until finished.");
            my $strSSHCmd = "snapmirror show -destination-volume $volName -fields status";
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
                logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                logMsg( $LOG_WARN, "Retrieving replication relationship for $volName failed.");
                logMsg( $LOG_WARN, "Please contact MS Operations for assistance with Disaster Recovery failover.");
                runExit($exitWarn);
            } else {
                logMsg( $LOG_INFO, "Relationship show completed successfully." );
            }
            my $listnum = 0;
            my $count = $#out - 1;
            for my $j (0 ... $count ) {
                $listnum++;
                next if ( $listnum <= 3 );
                chop $out[$j];
                my @arr = split( /,/, $out[$j] );

                $status = $arr[$#arr-1];
            }
            logMsg($LOG_INFO, "Status of volume $volName is $status");
        }
        print color('bold cyan');
        logMsg( $LOG_INFO, "Relationship updated for volume ".$volName." completed successfully." );
        print color('reset');
    } else {
        logMsg($LOG_WARN,"Relationship for $volName is not currently active.");
        logMsg($LOG_WARN,"Please contact Microsoft Operations for assistance");
    }

}


#
# Name: runQuiesceSnapMirror
# Func: quiesces replication relationsip ensuring that all production data has been replicated and then stopping replication
#

sub runQuiesceSnapMirror
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Quiescing Relationships by Volume**********************");
print color('reset');
         for my $i (0 .. $#replicationList) {


            my $strSSHCmd = "snapmirror quiesce -destination-volume ".$replicationList[$i];
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
          		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              logMsg( $LOG_WARN, "The replication relationship for ".$replicationList[$i]." could not be quiesced.");
              logMsg( $LOG_WARN, "Please try again in a few minutes");
              logMsg( $LOG_WARN, "If issue persists, please contact Microsoft Operations for assistance.");
              runExit($exitWarn);
            } else {
          		logMsg( $LOG_INFO, "Relationship quiesce for volume ".$replicationList[$i]." completed successfully." );
          	}
        }
}

sub runBreakSnapMirror {

print color('bold cyan');
logMsg($LOG_CRIT, "**********************Breaking Relationships by Volume**********************");
print color('reset');

         for my $i (0 .. $#replicationList) {

           my $volName = $replicationList[$i];
           my $state;
           my $status;
            do {

              my $strSSHCmd = "snapmirror show -destination-volume ".$volName. " -fields status, state";
              my @out = runSSHCmd( $strSSHCmd );
              my @strSubArr = split( /,/, $out[3] );
							$state = $strSubArr[$#strSubArr-1];
              $status = $strSubArr[$#strSubArr-2];
              logMsg($LOG_CRIT,"Volume:   ".$volName."   Status: $status     State: ".$state);



            } while ($state ne "Quiesced" and $status ne "Broken-off");
            if ($status ne "Broken-off") {
              my $strSSHCmd = "snapmirror break -destination-volume ".$volName;
              my @out = runSSHCmd( $strSSHCmd );
              if ( $? ne 0 ) {
            		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                logMsg( $LOG_WARN, "The replication relationship for ".$volName." could not be broken.");
                logMsg( $LOG_WARN, "Please reach out to Microsoft Operations for assistance");
                runExit($exitWarn);
              } else {
            		logMsg( $LOG_CRIT, "Relationship broken for volume ".$volName." completed successfully." );
            	}
            } else {
              logMsg( $LOG_CRIT, "Relationship already broken for volume ".$volName );
            }
        }
}

#
# Name: runRestoreSnapshot
# Func: restores volume of latest snapshot in the data volumes and log backups volume
#

sub runRestoreSnapshot
{
print color('bold cyan');
logMsg($LOG_CRIT, "**********************Restoring Snapshots by Volume**********************");
print color('reset');

         for my $i (0 .. $#snapshotCloneList) {
            my $volName = $snapshotCloneList[$i][0];
            my $snapshotName = $snapshotCloneList[$i][1];
            logMsg($LOG_CRIT, "Volume Name ". $volName);
            logMsg($LOG_CRIT, "Volume Name ". $snapshotName);
            if ($volName eq "") {
              next;
            }
            my $strSSHCmd = "snapshot restore -volume ".$volName." -snapshot ".$snapshotName." -force true";
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
          		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              logMsg( $LOG_WARN, "Snapshot cloned for ".$volName."  failed.");
              logMsg( $LOG_WARN, "Please reach out to Microsoft Operations for assistance.");
              runExit($exitWarn);
            } else {
              print color('bold green');
              logMsg( $LOG_CRIT, "Snapshot restored for volume ".$volName." completed successfully." );
              print color('reset');
              push(@arrClones, $volName);
              push(@displayMounts, $volName);
            }
        }


       print color('bold green');
       logMsg($LOG_INFO, "**********************All volumes restored sucessfully**********************");
       print color('reset');
}

#
# Name: runMountDRVolumes
# Func: Mounts the newly restored volumes to the NFS server namespace
#

sub runMountDRVolumes {

print color('bold cyan');
logMsg($LOG_CRIT, "**********************Mounting Dr Volumes by Volume**********************");
print color('reset');
    for my $i (0 .. $#arrClones) {
        my $strSSHCmd = "volume mount -volume ".$arrClones[$i]." -junction-path /".$arrClones[$i]." -active true";
        my @out = runSSHCmd( $strSSHCmd );
        if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
          logMsg( $LOG_WARN, "Volume Mount for ".$arrClones[$i]."  failed.");
          logMsg( $LOG_WARN, "Please reach out to Microsoft Operations for assistance.");
          runExit($exitWarn);
        } else {
          logMsg( $LOG_INFO, "Volume ".$arrClones[$i]." mounted successfully." );
        }
    }
}

#
# Name: runDisplayMountPoints
# Func: display the mount points customer will place in /etc/fstab
#

sub runDisplayMountPoints {

    print color('bold cyan');
    logMsg($LOG_CRIT, "**********************Collecting Mount Point Details**********************");
    print color('reset');
    my $strMountOptions = "nfs      rw,bg,hard,timeo=600,vers=4,rsize=1048576,wsize=1048576,intr,noatime,lock 0 0";
    my $j = 0;
    for my $i (0 .. $#displayMounts) {
      my $volName = $displayMounts[$i];
#      logMsg($LOG_CRIT, "Volume: ".$volName);
      if ((($volName !~ /data/ and $volName !~ /log_backups/ ) and ($volName =~ /dp/ or $volName =~ /xdp/)) or (($volName !~ /log/ and $volName !~ /shared/ and $volName !~ /usr_sap/) and $volName =~ /vol/)) {
          logMsg($LOG_INFO, "Skipping $volName");
          next;
      }
      my $strSSHCmd = "volume show -volume ".$volName." -fields node";
      my @out = runSSHCmd( $strSSHCmd );
      if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Unable to find location of ".$volName);
        logMsg( $LOG_WARN, "Please reach out to Microsoft Operations for assistance with mount points.");
        runExit($exitWarn);
      } else {
        logMsg( $LOG_INFO, "Located location of ".$volName);
      }
      my @strSubArr = split( /,/, $out[3] );
      my $node = $strSubArr[$#strSubArr-1];

      $strSSHCmd = "network interface show -home-node ".$node." -data-protocol nfs -fields address";
      my @outAddress = runSSHCmd( $strSSHCmd );
      if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Please reach out to Microsoft Operations for assistance with mount points.");
        runExit($exitWarn);
      } else {
        logMsg( $LOG_INFO, "Address found of ".$volName);
      }
      my @strSubArrAddress = split( /,/, $outAddress[3] );
      my $address = $strSubArrAddress[$#strSubArrAddress-1];

      $addressLocations[$j][0] = $volName;
      $addressLocations[$j][1] = $address;
      $j++;
    }
    print color('bold cyan');
    logMsg($LOG_INFO, "**********************Displaying Mount Points by Volume**********************");
    print color('reset');
    my $mountNode;
    my $strHANASID = uc $strHANASID;
    for my $i (0 .. $#addressLocations) {

                #logMsg($LOG_INFO,$addressLocations[$i][0]);
                if ($addressLocations[$i][0] =~ /mnt/) {

                    my @arr = split(/_/,$addressLocations[$i][0]);
                    for my $j (0 .. $#arr) {
                      #print $arr[$j]."\n";
                      if ($arr[$j] =~ /mnt/) {
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

                if ($addressLocations[$i][0] =~ m/data/  and ($addressLocations[$i][0] =~ m/xdp/ or $addressLocations[$i][0] =~ m/dp/) ) {

                    logMsg($LOG_CRIT,$addressLocations[$i][1].":/".$addressLocations[$i][0]."   /hana/data/".$strHANASID."/".$mountNode."   ".$strMountOptions);

                }
                if ($addressLocations[$i][0] =~ m/log/ and $addressLocations[$i][0] !~ m/log_backups/ and ($addressLocations[$i][0] !~ m/dp/ and $addressLocations[$i][0] !~ m/xdp/) )  {

                    logMsg($LOG_CRIT,$addressLocations[$i][1].":/".$addressLocations[$i][0]."   /hana/log/".$strHANASID."/".$mountNode."   ".$strMountOptions);

                }
                if ($addressLocations[$i][0] =~ m/shared/ and ($addressLocations[$i][0] !~ m/dp/ and $addressLocations[$i][0] !~ m/xdp/) ) {

                    for my $j (0 .. $#qtreeLocations) {
                        if ($qtreeLocations[$j] =~ m/shared/) {
                          logMsg($LOG_CRIT,$addressLocations[$i][1].":/".$addressLocations[$i][0]."/".$qtreeLocations[$j]."   /hana/shared/".$strHANASID."   ".$strMountOptions);
                        } elsif ($qtreeLocations[$j] =~ m/sap/) {
                          logMsg($LOG_CRIT,$addressLocations[$i][1].":/".$addressLocations[$i][0]."/".$qtreeLocations[$j]."   /usr/sap/".$strHANASID."   ".$strMountOptions);
                        }
                    }
                }
                if ($addressLocations[$i][0] =~ m/log_backups/  and ($addressLocations[$i][0] =~ m/xdp/ or $addressLocations[$i][0] =~ m/dp/) ) {

                    logMsg($LOG_CRIT,$addressLocations[$i][1].":/".$addressLocations[$i][0]."   /hana/logbackups/".$strHANASID."   ".$strMountOptions);
                }

     }
     print color('bold cyan');
     logMsg($LOG_INFO, "********************************************************************");
     print color('reset');


}

#
# Name: runDisplayRecoverySteps
# Func: display the mount points customer will place in /etc/fstab
#
sub runDisplayRecoverySteps {

    print color('bold cyan');
    logMsg($LOG_CRIT,"**********************HANA DR Recovery Steps**********************");
    print color('reset');
    logMsg($LOG_CRIT,"1. Copy Mount Point Details into /etc/fstab of DR Server.");
    logMsg($LOG_CRIT,"2. Mount newly added filesystems.");
    logMsg($LOG_CRIT,"3. Perform HANA Snapshot Recovery using HANA Studio.");
    print color('bold cyan');
    logMsg($LOG_CRIT,"***********************************************************************");
    print color('reset');
}

#
# Name: runResumeSnapMirror
# Func: resumes paused replication relationship after it was quiesced
#

sub runResumeSnapMirror
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Resuming Relationships by Volume**********************");
print color('reset');
         for my $i (0 .. $#replicationList) {


            my $strSSHCmd = "snapmirror resume  -destination-volume ".$replicationList[$i][0];
            my @out = runSSHCmd( $strSSHCmd );
            if ( $? ne 0 ) {
          		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              logMsg( $LOG_WARN, "The replication relationship for ".$replicationList[$i][0]." could not be resumed.");
              logMsg( $LOG_WARN, "Please reach out to Microsoft Operations for assistance.");
              runExit($exitWarn);
            } else {
          		logMsg( $LOG_INFO, "Relationship resume for volume ".$replicationList[$i][0]." completed successfully." );
          	}

        }
}

#
# Name: displayArray
# Func: Displays all snapshots by corresponding volume
#

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

#
# Name: displaySnapmirrorVolumesArray
# Func: Displays the replication list
#

sub displaySnapmirrorVolumesArray
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Displaying Relationships by Volume**********************");
print color('reset');
         for my $i (0 .. $#replicationList) {


                         logMsg($LOG_INFO,$replicationList[$i]);

                }


}

#
# Name: runClearVolumeLocations()
# Func: Clears the list of volumes for next SID
#

sub runClearVolumeLocations
{
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Clearing volume list**********************");
  print color('reset');
  undef @volLocations;
}

#
# Name: runPrintFile()
# Func: Prints contents of $LOG_INFO, $LOG_INFO, and $LOG_WARN to log file within snanshotLogs directory
#

sub runPrintFile
{
	my $myLine;
  if (defined($strHANASID)) {
      $outputFilename = "testDR.$strHANASID.$date.txt";
  } else {
      $outputFilename = "testDR.$date.txt";
  }
  my $existingdir = './snapshotLogs';
	mkdir $existingdir unless -d $existingdir; # Check if dir exists. If not create it.
	open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
  print color('bold green');
  logMsg($LOG_CRIT, "Log file created at ".$existingdir."/".$outputFilename);
  print color('reset');
  foreach $myLine (@arrOutputLines) {
	     print $fileHandle $myLine;
	}
	close $fileHandle;
}

##### --------------------- MAIN CODE --------------------- #####
logMsg($LOG_INFO,"Executing Azure HANA Test DR Failover Script, Version $version");
if (defined($ARGV[0])) {
  if ($ARGV[0] eq "verbose" or $ARGV[0] eq "-v") {
    $verbose = 1;
  }
}

logMsg($LOG_CRIT,"Executing Azure HANA DR Failover Script, Version $version");
my $inputProceed;
my $strHello = "This script is designed for those customers who have previously installed the Production HANA instance in the Disaster Recovery Location either as a stand-alone instance or as part of a multi-purpose environment. This script should only be run in the event of a declared disaster by Microsoft or as part of required Disaster Recovery testing plans. A failback coordinated with Microsoft Operations is required after this script has been executed.  WARNING: the failback process will not necessarily be a quick process and will require multiple steps in coordination with Microsoft Operations so this script should not be undertaken lightly.  This script will restore only the most recent snapshot for both the Data and Log Backups filesystems.  Any other restore points must be handled by Microsoft Operations.  Please enter the HANA <SID> you wish to restore. This script must be executed from the Disaster Recovery location otherwise unintended actions may occur.\n";
$strHello =~ s/([^\n]{0,120})(?:\b\s*|\n)/$1\n/gio;
logMsg($LOG_INPUT, $strHello);
push (@arrOutputLines, $strHello);
do {
  logMsg($LOG_INPUT, "Please enter (yes/no):  ");
  $inputProceed = <STDIN>;
  $inputProceed =~ s/[\n\r\f\t]//g;
  if ($inputProceed =~ m/no/i) {
    runExit($exitCode);
  }
} while ($inputProceed !~ m/yes/i);

do {

  my $strHANASIDInput = "Please enter either the HANA SID you wish to restore:   ";
  logMsg($LOG_INPUT, $strHANASIDInput);
  my $inputHANASID = <STDIN>;
  $inputHANASID =~ s/[\n\r\f\t]//g;
  $strHANASID = lc $inputHANASID;

} while (length $strHANASID ne 3);

#read and store each line of HANABackupCustomerDetails to fileHandle
runOpenParametersFiles();

#verify each line is expected based on template, otherwise throw error.
runVerifyParametersFile();

#add Parameters to usable array customerDetails
runGetParameterDetails();

#verify all required details entered for each SID
runVerifySIDDetails();


my $i = 0;
while ($arrCustomerDetails[$i][0] ne $strHANASID) {

  if ($i eq $numSID) {

      logMsg($LOG_WARN, "The Entered SID was not found within the HANABackupCustomerDetails.txt file.  Please double-check that file.");
      print color('bold red');
      runExit( $ERR_WARN );

    }
    if ($arrCustomerDetails[$i][0] eq $strHANASID) {
      last;
    }
    $i++;
}

$strUser = $arrCustomerDetails[$i][1];
$strSVM = $arrCustomerDetails[$i][2];

# get volume(s) to take a snapshot of
runGetVolumeLocations();

#get Qtree locations for shared volume
runGetQtreeLocations();

#get SnapMirror relationships
runGetSnapmirrorVolumes();
displaySnapmirrorVolumesArray();

#updates SnapMirror relationships
runUpdateSnapMirror();

#Quiesces SnapMirror relationships
runQuiesceSnapMirror();

#get snapshots by volume and place into array
runGetSnapshotsByVolume();
displayArray();

#verify either HANA Backup ID or snapshot name is found
runVerifySnapshotsExist();

#break SnapMirror relationships
runBreakSnapMirror();

#restores snapshots
runRestoreSnapshot();

#mounts DR volumes to namespace
runMountDRVolumes();

#displays mount points of DR volumes
runDisplayMountPoints();

# time to exit
runExit( $ERR_NONE );
