#!/usr/bin/perl -w
#
# Copyright (C) 2017 Microsoft, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: azure_hana_backup.pl
#Version: 3.3
#Date 05/15/2018

use strict;
use warnings;
use Time::Piece; #takes system current time and converts to usable format
use Date::Parse;
use Time::HiRes; #allows usage of tenths of second in wait command
use Term::ANSIColor;
use Sys::Hostname;
#number of allowable SIDs. Number entered is one less than actual.. i.e if allowing 4 SIDs, then 3 is entered
my $numSID = 9;
my $detailsStart = 11;
#Usage:  This script is used to allow Azure HANA customers to create on-demand backups of their various HANA volumes.  The variable $numkeep describes the number of backup related snapshots that are created within
#		protected volumes. The backup is created through the snapshot process within NetApp.  This snapshot is created by calling the customer's Storage Virtual Machine and executing a snapshot.  The snapshot is given
#		a snapmirror-label of customer. The snapshot is then replicated to a backup folder using SnapVault.  SnapVault will have its own retention schedule that is kept independent of this script.
#
#
#
# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE=0;
my $ERR_WARN=1;

# Log levels -- LOG_INFO, LOG_CRIT, LOG_WARN.  Bitmap values
my $LOG_INFO=1; #standard output to file or displayed during verbose
my $LOG_CRIT=2; #displays only critical output to console and log file
my $LOG_WARN=3; #displays any warnings to console and log file


# Global parameters

my $exitWarn = 0;
my $exitCode;

my $verbose = 0;
my $strBackupType = $ARGV[0]; #type of backup deployed. Options include hana, logs, and boot.

#
# Global Tunables
#

#DO NOT MODIFY THESE VARIABLES!!!!
my $version = "3.3";  #current version number of script
my @arrOutputLines;                   #Keeps track of all messages (Info, Critical, and Warnings) for output to log file
my @fileLines;                        #Input stream from HANABackupCustomerDetails.txt
my @strSnapSplit;
my @arrCustomerDetails;               #array that keeps track of all inputs on the HANABackupCustomerDetails.txt
my $strHANABackupID;                  #Backup ID number created during HANA backup process.
my $strPrimaryHANAServerName;         #Customer provided IP Address or Qualified Name of Primay HANA Server.
my $strPrimaryHANAServerIPAddress;    #Customer provided IP address of Primary HANA Server
#my $strPrimaryHANAServerNameScript;   #converts "-" in a hostname to "_" since "-" is not readable in storage
#my $strSecondaryHANAServerNameScript; #converts "-" in a hostname to "_" since "-" is not readable in storage

my $filename = "HANABackupCustomerDetails.txt";
my $numKeep;                          #Customer provided retention number for snapshots by customer provided by snapshot prefix.
my $strSnapshotPrefix;                #The customer entered snapshot prefix that precedes the date in the naming convention for the snapshot
my $strSnapshotCustomerLabel;         #Label provided by customer to snapshot that determines how SnapVault and SnapLock will handle snapshots.
                                      #Currently, allowed values are 5min and 15min for logs and hourly for data
my $strUser;                          #Microsoft Operations provided storage user name for backup access
my $strSVM;                           #IP address of storage client for backup
my $strHANANumInstance;               #the two digit HANA instance number (e.g. 00) the customer uses when installing HANA SIDs
my $strHANAAdmin;                     #Hdbuserstore key customer sets for paswordless access to hdbsql
my $strOSBackupType = "none";         #Input command when customer selects boot backup between Type1 and TypeII
my $cloneSnapshot = 0;                #keeps track of whether any snapshots in production are cloned in DR
my $numSnapshotCount = 0;             #Count of number of snapshots that match snapshot prefix versus total number of snapshots in volume
my $intMDC;                           #Boolean for determining whether MDC environment is detected. 1 - Yes, 0 - No
my $sshCmd = '/usr/bin/ssh';          #typical location of ssh on SID
my $strHANASID;                       #The customer entered HANA SID for each iteration of SID entered with HANABackupCustomerDetails.txt
my $hanaSnapshotSuccess = qq('Storage snapshot successful');
                                      #required string for successful closure of HANA snapshot
my $strHANAIDRequestString = "select BACKUP_ID from M_BACKUP_CATALOG where ENTRY_TYPE_NAME = 'data snapshot' and STATE_NAME = 'prepared'";
                                      #HDBSQL command necessary to obtain HANA Backup ID after creating HANA Snapshot
my $strHANAStatusCmdV1;               #generated command for HANA Version 1 to test access by requesting HANA DB status
my $strHANAStatusCmdV2;               #generated command for HANA Version 2 to test access by requesting HANA DB status
my $strHANACreateSnapCmdV1;           #generated command for HANA Version 1 to create HANA snapshot within hdbsql
my $strHANACreateSnapCmdV2;           #generated command for HANA Version 2 to create HANA snapshot within hdbsql
my $strHANABackupIDRequestV1;         #command for HANA Version 1 to obtain HANA Backup ID for newly created HANA snapshot
my $strHANABackupIDRequestV2;         #command for HANA Version 2 to obtain HANA Backup ID for newly created HANA snapshot
my $strHANACloseCmdV1;                #generated command for HANA Version 1 to close HANA snapshot within hdbsql
my $strHANACloseCmdV2;                #generated command for HANA Version 2 to close HANA snapshot within hdbsql

my $strHANAVersion;                   #HANA Major Version Number
my $strHANARevision;                  #HANA Revision release Number. Currently necessary to determine if HANA 2.0 install suports both MDC and HANA Snapshot

my $outputFilename = "";              #Generated filename for scipt output
my @snapshotLocations;                #arroy of all snapshots for certain volumes that match customer SID.
my @volLocations;                     #array of all volumes that match SID input by customer
my $strHANASIDUC;                     #uppercase SID
my $tenant;                           #tenant number


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
    runExit($exitWarn);
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

#
# Name: runSSHDiagCmd
# Func: Run an SSH command as special Diagnostic access. Required for certain fields in storage
#

sub runSSHDiagCmd
{
	;
	my ( $strShellCmd ) = @_;
	return(  `"$sshCmd" -l $strUser $strSVM 'set diag -confirmations off -showseparator ","; $strShellCmd' 2>&1` );
}

#
# Name: runCheckHANAVersion()
# Func: Checks version of HANA to determine which type of hdbsql commands to use. Identifies whether MDC environment is present and current Hana
#       version and revision number.
#
sub runCheckHANAVersion
{
    my $strHANASIDTemp = uc $strHANASID;
    my $strDirectory1 =  '/hana/shared/'.$strHANASIDTemp.'/global/hdb/mdc';
    my $strDirectory2 =  '/hana/shared/'.$strHANASIDTemp.'/'.$strHANASIDTemp.'/global/hdb/mdc';
    my $strHANAVersionCMD = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "select version from sys.m_database"';
    my $strHANAVersionTemp;
    my @arrHANAVersion;
    #first check whether MDC environment or not
    logMsg($LOG_INFO, "Checking $strDirectory1 for MDC");
    logMsg($LOG_INFO, "Checking $strDirectory2 for MDC");
    if (-d $strDirectory1 or -d $strDirectory2) {
      $intMDC = 1;
      print color('bold green');
      logMsg($LOG_CRIT,"Detected MDC environment for $strHANASIDTemp.");
      print color('reset');
    } else {
      $intMDC = 0;
      print color('bold green');
      logMsg($LOG_CRIT,"Detected non-MDC environment for $strHANASIDTemp.");
      print color('reset');
    }

    logMsg( $LOG_CRIT, "Checking HANA Version with command: \"$strHANAVersionCMD\" ..." );
    my @out = runShellCmd( $strHANAVersionCMD );
    if ( $? ne 0  ) {
       logMsg($LOG_WARN, "HANA appears to be down.");
       logMsg($LOG_WARN, "If you feel this is in error, Please contact Microsoft Operations");
       runExit($exitWarn);
     }
    $strHANAVersionTemp = $out[1];
    $strHANAVersionTemp =~ s/\"//g;
    logMsg($LOG_CRIT,"Version: $strHANAVersionTemp");
    @arrHANAVersion = split(/\./, $strHANAVersionTemp);
    $strHANAVersion = $arrHANAVersion[0];
    $strHANARevision = $arrHANAVersion[2];
    my $strHANARevisionLong = $arrHANAVersion[2];
    if (substr($strHANARevision,0,1) eq 0) {
      $strHANARevision = substr($strHANARevision,1,2);
    }
    print color('bold green');
    logMsg( $LOG_CRIT, "HANA Version: $strHANAVersion Revision Number: $strHANARevisionLong");
    print color('reset');
}

#
# Name: runCheckHANAStatus()
# Func: Verfies customer access to HANA database by checking HANA DB status before continuing script
#

sub runCheckHANAStatus
{
      print color('bold cyan');
      logMsg($LOG_CRIT, "**********************Checking HANA status**********************");
      print color('reset');
      # Create a HANA database username via HDBuserstore
      if ($intMDC eq 0) {
        my @out = runShellCmd( $strHANAStatusCmdV1 );
        logMsg($LOG_CRIT, $strHANAStatusCmdV1);
      }
      if ($intMDC eq 1) {
        my @out = runShellCmd( $strHANAStatusCmdV2 );
        logMsg($LOG_CRIT, $strHANAStatusCmdV2);
      }
      if ( $? ne 0 ) {
        if ($strHANAVersion eq 1) {
            logMsg( $LOG_WARN, "HANA check status command '" . $strHANAStatusCmdV1 . "' failed: $?" );
        }
        if ($strHANAVersion eq 2) {
            logMsg( $LOG_WARN, "HANA check status command '" . $strHANAStatusCmdV2 . "' failed: $?" );
        }
        logMsg( $LOG_WARN, "Please check the following:");
        logMsg( $LOG_WARN, "HANA Instance is up and running.");
        logMsg( $LOG_WARN, "In an HSR Setup, this script will not function on current secondary node.");
        logMsg( $LOG_WARN, "hdbuserstore user command was executed with root");
        logMsg( $LOG_WARN, "Backup user account created in HANA Studio was made under SYSTEM");
        logMsg( $LOG_WARN, "Backup user account and hdbuserstore user account are case-sensitive");
        logMsg( $LOG_WARN, "The correct host name and port number are used");
        logMsg( $LOG_WARN, "The port number in 3(".$strHANANumInstance.")15 [for non-MDC] and 3(".$strHANANumInstance.")13 [for MDC] corresponds to instance number of ".$strHANANumInstance." when creating hdbuserstore user account");
        logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
        runExit($exitWarn);
      } else {
          logMsg( $LOG_CRIT, "HANA status check successful." );
      }
}


#
# Executes rear tool for TYPEII OS Backups
#
sub runTYPEIIBackup() {

logMsg($LOG_CRIT,"Creating backup of ".$strHANASID." using rear tool.");


      my $strREARBackup = "rear -v mkbackup";
      my @out = runShellCmd( $strREARBackup );
      if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "Server backup command $strREARBackup failed." );
          logMsg( $LOG_WARN, "Please reach out to Microsoft Operations");
					runExit($exitWarn);
				} else {
					logMsg( $LOG_CRIT, "Server Backup created successfully.");
			}
}

#
# Name: runGetVolumeLocations()
# Func: Get the set of production volumes that match specified HANA instance.
# Options: If backup type is hana then collects the data and shared volumes that correspond to customer specified SID
#          If backup type is logs then collects only log backups volume that correspond to customer specified SID
#          TypeI - collects all boot volumes for given customer
#          TypeII - specific to customer input of Server HANA name
sub runGetVolumeLocations
{
  my $strSSHCmd;
  if ($strBackupType eq "hana") {
     print color('bold cyan');
     logMsg($LOG_CRIT, "**********************Getting list of volumes that match HANA instance specified**********************");
     print color('reset');
     logMsg( $LOG_CRIT, "Collecting set of volumes hosting HANA matching pattern *$strHANASID* ..." );
	   $strSSHCmd = "volume show -volume *".$strHANASID."* -state online -volume !*log_backups* -volume !*log* -type RW -fields volume";
  }
  if ($strOSBackupType eq "TYPEI") {
     print color('bold cyan');
     logMsg($LOG_CRIT, "**********************Getting list of volumes of boot volumes**********************");
     print color('reset');
     $strSSHCmd = "volume show -volume *boot* -type RW -state online -fields volume";
  }
  if ($strBackupType eq "logs") {
    print color('bold cyan');
    logMsg($LOG_CRIT, "**********************Getting list of volumes that match HANA instance specified**********************");
    print color('reset');
    logMsg( $LOG_CRIT, "Collecting set of volumes hosting HANA matching pattern *$strHANASID* ..." );
	  $strSSHCmd = "volume show -volume *log_backups_".$strHANASID."* -state online -type RW -fields volume";
  }

  if ($strOSBackupType eq "TYPEII") {
     print color('bold cyan');
     logMsg($LOG_CRIT, "**********************Getting list of volumes of boot volumes**********************");
     print color('reset');
     $strSSHCmd = "volume show -volume *".$strPrimaryHANAServerName."_os* -type RW -fields volume";
  }

  my @out = runSSHCmd( $strSSHCmd );
	if ( $? ne 0 ) {
		logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
    logMsg( $LOG_WARN, "Please double check that your HANABackupCustomerDetails sheet includes the correct SID or HANA Server Name depending on backup type");

	} else {
		logMsg( $LOG_CRIT, "Volume collection completed successfully." );
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
      if (!defined($tenant)) {
        $tenant = $arr[$#arr-2];
      }
			if (defined $name) {
				logMsg( $LOG_CRIT, "Adding volume $name to the snapshot list." );
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
		if ($volName eq $snapshotLocations[$i][0][0]){
			logMsg( $LOG_INFO, "$volName found." );
			#with the volume found, each snapshot associated with that volume is now examxined
			my $aref = $snapshotLocations[$i];
			for my $j (0 .. $#{$aref} ) {
				@strSnapSplit = split(/\./, $snapshotLocations[$i][$j][0]);
				if (defined $strSnapSplit[2]) {
						$tempSnapName = $strSnapSplit[0].".".$strSnapSplit[2];
				} else {
						$tempSnapName = "";
				}
				if ( $tempSnapName eq $snapName ) {
					logMsg( $LOG_INFO, "Snapshot $snapName on $volName found." );
					return($snapshotLocations[$i][$j][0]);
				}
			}
		}
	}
	logMsg( $LOG_INFO, "Snapshot $snapName on $volName not found." );
	return( "0" );

}


#
# Name: runRotateSnapshots()
# Func: Rotates the snapshots from 0 to #numKeep-2 up one number
#
sub runRotateSnapshots
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Rotating snapshot numbering to allow new snapshot**********************");
print color('reset');
my $rotateIndex;
my $checkSnapshotResult = "";
	# let's go through all the Filer and volume paths, rotating snapshots for each
for my $i (0 .. $#snapshotLocations) {
		# set up our loop counters
    my $aref = $snapshotLocations[$i];
    my $arraySize = $#{$aref} +1 ;


    #determine whether the retention entry from customer is smaller than number of snapshots and sets index
    if ($arraySize <= $numKeep) {
        $rotateIndex = $arraySize;

    } else {
        $rotateIndex = $numKeep;
    }

    my $j = $rotateIndex;
		my $k = $rotateIndex - 1;

    logMsg($LOG_INFO, "j: $j  k: $k");
		# get the SVM and volume name(s)
		my $volName = $snapshotLocations[$i][0][0];


    my $checkSnapshotResult;
		# iterate through all the snapshots
		logMsg( $LOG_INFO, "Rotating snapshots named $strSnapshotPrefix.# on $snapshotLocations[$i][0][0] ..." );

		while ( $k >= 0 ) {

      $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotPrefix\.$k" );

			if ( $checkSnapshotResult ne "0") {
        Time::HiRes::sleep (0.5+rand(0.5));
				my @strSnapSplit = split(/\./, $checkSnapshotResult);
        logMsg($LOG_INFO, "Renaming Snapshot ".$strSnapSplit[0].".".$k." to ".$strSnapSplit[0].".".$j);
				my $strSSHCmd = "volume snapshot rename -volume $volName -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.$k -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.$j";
				my @out = runSSHCmd( $strSSHCmd );
				if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
          logMsg( $LOG_WARN, "Pleae try again in a few minutes. If issue persists, please contact Microsoft Operations");
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
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Deleting oldest snapshot list**********************");
	if ($iteration eq "1") {
			logMsg($LOG_INFO, "**********************Failure removing oldest snapshot acceptable**********************");
	}
	if ($iteration eq "2") {
			logMsg($LOG_INFO, "**********************Failure removing oldest snapshot unacceptable unless clones exist**********************");
	}
  print color('reset');
  for my $i (0 .. $#snapshotLocations) {
		# let's make sure the snapshot is there first
    my $volName = $snapshotLocations[$i][0][0];
    my $snapshotName = "$strSnapshotPrefix\.$numKeep";

    my $checkSnapshotResult = runCheckIfSnapshotExists( $volName, $snapshotName );
    my $lockedSnapshot = runCheckSnapshotLocked($volName,$checkSnapshotResult);
    logMsg($LOG_INFO, "Result: $checkSnapshotResult   Locked: $lockedSnapshot");
    if ( $checkSnapshotResult eq "0") {

			logMsg( $LOG_INFO, "Oldest snapshot " . $strSnapshotPrefix . "." . $numKeep . " does not exist on $snapshotLocations[$i][0][0]." );

		} elsif ($lockedSnapshot ne "0") {

      logMsg( $LOG_CRIT, "Snapshot $strSnapshotPrefix\.$numKeep on $volName is locked and will be kept at index: $numKeep");

    } else {
      logMsg( $LOG_CRIT, "Removing oldest snapshot $strSnapshotPrefix\.$numKeep on $snapshotLocations[$i][0][0] on SVM $strSVM ..." );
			my $strSSHCmd = "volume snapshot delete -volume $snapshotLocations[$i][0][0] -snapshot $checkSnapshotResult";
			my @out = runSSHCmd( $strSSHCmd );
			if ( $? ne 0 ) {
				logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Please try again in a few minutes. If issue persists, please contact Microsoft Operations");
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
print color('bold cyan');
logMsg($LOG_INFO, "**********************Deleting existing *.recent snapshot**********************");
logMsg($LOG_INFO, "**********************Failures are allowed if *.recent was properly cleaned up last backup**********************");
print color('reset');
	for my $i (0 .. $#snapshotLocations) {
		# let's make sure the snapshot is there first
    my $volName = $snapshotLocations[$i][0][0];
    my $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotPrefix\.recent");
		if ($checkSnapshotResult eq "0") {
			logMsg( $LOG_INFO, "Recent snapshot $strSnapshotPrefix\.recent does not exist on $snapshotLocations[$i][0][0]." );
		} else {
			# delete the recent snapshot
			logMsg( $LOG_INFO, "Removing recent snapshot $strSnapshotPrefix\.recent on $snapshotLocations[$i][0][0] on SVM $strSVM ..." );
			logMsg($LOG_INFO, $checkSnapshotResult);
			my $strSSHCmd = "volume snapshot delete -volume $snapshotLocations[$i][0][0] -snapshot $checkSnapshotResult";

			my @out = runSSHCmd( $strSSHCmd );
			if ( $? ne 0 ) {
				logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Please try again in a few minutes. If issue persists, please contact Microsoft Operations");
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
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Renaming *.recent snapshot to *.0**********************");
  print color('reset');
  for my $i (0 .. $#snapshotLocations) {
		logMsg( $LOG_INFO, "Renaming snapshot $strSnapshotPrefix\.recent to $strSnapshotPrefix\.0 for $snapshotLocations[$i][0][0] on SVM $strSVM ..." );
		my $checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0][0], "$strSnapshotPrefix\.recent");
		if ($checkSnapshotResult eq "0") {
			logMsg( $LOG_CRIT, "Recent snapshot $strSnapshotPrefix\.recent does not exist on $snapshotLocations[$i][0][0]." );
		} else {
				my @strSnapSplit = split(/\./, $checkSnapshotResult);
				#logMsg($LOG_INFO,$checkSnapshotResult);
				my $strSSHCmd = "volume snapshot rename -volume $snapshotLocations[$i][0][0] -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.recent -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.0";
				my @out = runSSHCmd( $strSSHCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
            logMsg( $LOG_WARN, "$strSnapshotPrefix.recent could not be renamed. This is most likely because of an error rotating snapshot index up for previous snapshots");
				} else {
						logMsg( $LOG_INFO, "Snapshot rename completed successfully." );
				}
		}
	}
}


#
# Name: runCreateHANASnapshot()
# Func: Creates the HANA snapshot based on version of HANA. Throws an error if customer is running MDC unless they are running HANA 2 SP1 or greater.
#
sub runCreateHANASnapshot
{
	if ($strBackupType eq "hana") {

      my $strHANACreateCmd;
      print color('bold cyan');
      logMsg($LOG_CRIT, "**********************Creating HANA snapshot**********************");
      print color('reset');
      # Create a HANA database snapshot via HDBuserstore, key snapper

      if ($intMDC eq 0) {
        $strHANACreateCmd = $strHANACreateSnapCmdV1;
      }
      if ($intMDC eq 1 and $strHANAVersion eq 2 and $strHANARevision ge 10) {
        $strHANACreateCmd = $strHANACreateSnapCmdV2;
      }

      if ($intMDC eq 1 and $strHANAVersion eq 1) {
        logMsg($LOG_CRIT,"MDC Architecture and HANA Version 1 Detected.");
        logMsg($LOG_WARN,"SAP does not support snapshots in a MDC environment for the currently detected release. Snapshots are supported as a non-MDC install on the detected release.");
        runExit($exitWarn);
      }
      if ($intMDC eq 1 and $strHANAVersion eq 2 and $strHANARevision lt 10) {
        logMsg($LOG_WARN,"MDC architecture and HANA Version 2 SP 00 Detected.");
        logMsg($LOG_WARN,"SAP does not support snapshots in a MDC environment for the currently detected release. Snapshots are supported as a non-MDC install on the detected release.");
        runExit($exitWarn);
      }
      logMsg( $LOG_CRIT, "Creating the HANA snapshot with command: \"$strHANACreateCmd\" ..." );
			my @out = runShellCmd( $strHANACreateCmd );
			if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "HANA snapshot creation command '" . $strHANACreateCmd . "' failed: $?" );
          if ($intMDC eq 1 and $strHANAVersion eq 2 and $strHANARevision ge 10) {
            logMsg($LOG_WARN,"Please ensure this is a single tenant system.");
            logMsg($LOG_WARN,"HANA Snapshot for multitenant system is not currently supported by SAP.");
            logMsg($LOG_WARN,"Please verify that a HANA Snapshot is not already open.");

          }
          logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
					runExit($exitWarn);
				} else {
          print color ('bold green');
          logMsg( $LOG_CRIT, "HANA snapshot created successfully." );
          print color ('reset');
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
      print color('bold cyan');
      logMsg($LOG_CRIT, "**********************Checking for HANA snapshot and obtaining ID**********************");
      print color('reset');
      # Create a HANA database snapshot via HDBuserstore, key snapper
      if ($strHANAVersion eq 1) {
        logMsg( $LOG_CRIT, "Checking HANA snapshot status with command: \"$strHANABackupIDRequestV1\" ..." );
        @out = runShellCmd( $strHANABackupIDRequestV1 );
        $strRequest = $strHANABackupIDRequestV1;
      }
      if ($strHANAVersion eq 2) {
        logMsg( $LOG_CRIT, "Checking HANA snapshot status with command: \"$strHANABackupIDRequestV2\" ..." );
        @out = runShellCmd( $strHANABackupIDRequestV2 );
        $strRequest = $strHANABackupIDRequestV2;
      }
      logMsg( $LOG_INFO, 'row 1'.$out[1] );
      $strHANABackupID = $out[1];
      $strHANABackupID =~ s/\r|\n//g;
      logMsg( $LOG_INFO, 'hanabackup id: '.$strHANABackupID);
      if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "HANA snapshot creation command '" . $strRequest . "' failed: $?" );
          logMsg( $LOG_WARN, "Most likely cause of HANA snapshot failure is a previous HANA snapshot was never closed or deleted.");
          logMsg( $LOG_WARN, "Please investigate backup status of $strHANASID and try again.");
          logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
          runExit($exitWarn);
        } else {
          print color('bold green');
          logMsg( $LOG_CRIT, "HANA snapshot backupid discovered:  $strHANABackupID." );
          print color('reset');
      }
  }
}



#
# Name: runCheckHANAVersion()
# Func: Closes HANA snapshot with backup ID for record keeping in HANA catalog
#

sub runHANACloseSnapshot
{
  if ($strBackupType eq "hana") {
      my $strHANACloseCmd;
      print color('bold cyan');
      logMsg($LOG_CRIT, "**********************Closing HANA snapshot**********************");
      print color('reset');
      # Delete the HANA database snapshot
      if ($strHANAVersion eq 1) {
        $strHANACloseCmdV1 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data close snapshot backup_id '. $strHANABackupID . ' SUCCESSFUL '.$hanaSnapshotSuccess.qq(");
        $strHANACloseCmd = $strHANACloseCmdV1;
      }
      if ($strHANAVersion eq 2) {
        $strHANACloseCmdV2 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U ' . $strHANAAdmin . ' "backup data for full system close snapshot backup_id '. $strHANABackupID . ' SUCCESSFUL '.$hanaSnapshotSuccess.qq(");
        $strHANACloseCmd = $strHANACloseCmdV2;
      }
      logMsg( $LOG_CRIT, "Closing the HANA snapshot with command: \"$strHANACloseCmd\" ..." );
      my @out = runShellCmd( $strHANACloseCmd );
      if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "HANA snapshot deletion command '" . $strHANACloseCmd . "' failed: $?" );
          logMsg( $LOG_WARN, "Please verify backup status of $strHANASID and close snapshot if necessary");
          logMsg( $LOG_WARN, "The command listed above may be used to close the snapshot.  If this command fails, please contact Microsoft Operations");
      } else {
          print color('bold green');
          logMsg( $LOG_CRIT, "HANA snapshot closed successfully." );
          print color('reset');
      }
  }

}

#
# Name: runCreateStorageSnapshot()
# Func: Takes a storage snapshot
#

sub runCreateStorageSnapshot
{
print color('bold cyan');
logMsg($LOG_CRIT, "**********************Creating Storage snapshot**********************");
print color('reset');
    my $hostname = hostname;
    logMsg( $LOG_INFO, "hostname: ". $hostname );
    my $strSSHCmd;

    my @arr = split( /\-/, $tenant );
    logMsg( $LOG_INFO, "Smaller tenant: ". $arr[2] );

    my $intLen = length($arr[2]);

    my $intIndex = index($arr[2], "v")+1;
    my $intSize = $intLen - $intIndex;
    my $strTNum = substr($arr[2],$intIndex, $intSize);
    my $strTenantNumber = "t".$strTNum;

    logMsg( $LOG_INFO, "Tenant Number: ". $strTenantNumber );
    logMsg( $LOG_INFO, "Backup Type: ". $strBackupType );
    for my $i (0 .. $#snapshotLocations) {
		    # take the recent snapshot with SSH
        $strSSHCmd = "";
        logMsg( $LOG_CRIT, "Verify snapshot $strSnapshotPrefix\.recent creation for $snapshotLocations[$i][0][0] ..." );
        #storage command necessary to create storage snapshot, others items to include: snapmirror-label matching snapshot type/frequency and HANA snapshot backup id matching as comment
        my $date = localtime->strftime('%Y-%m-%d_%H%M');
        my $volName = $snapshotLocations[$i][0][0];

        if ($strBackupType eq "hana") {

          my $volDataNoHSR = $strHANASID."_mnt";
          my $volSharedNoHSR = $strHANASID."_".$strTenantNumber;
          my $strDIRLocationCheck = "/hana/data/$strHANASIDUC/mnt00001/hdb00001";
          my $strDIRLocationCheck2 = "/hana/data/$strHANASIDUC/mnt00001/mnt00001/hdb00001";
          my $strSnapshotLocation = "/hana/data/$strHANASIDUC/mnt00001/hdb00001/snapshot_databackup_0_1";
          my $strSnapshotLocation2 = "/hana/data/$strHANASIDUC/mnt00001/mnt00001/hdb00001/snapshot_databackup_0_1";
          if (-e $strDIRLocationCheck) {
            logMsg($LOG_CRIT, "Checking for snapshot at $strSnapshotLocation");
          } elsif (-e $strDIRLocationCheck2) {
            logMsg($LOG_CRIT, "Checking for snapshot at $strSnapshotLocation2");
          } else {
            logMsg($LOG_WARN, "Unable to find suitable directory to check for location of HANA snapshot");
            runHANACloseSnapshot();
            runExit($exitWarn);
          }
          if ( ( ((-e $strSnapshotLocation) or (-e $strSnapshotLocation2)) and ($volName =~ m/$hostname/)) or ( ((-e $strSnapshotLocation) or (-e $strSnapshotLocation2)) and ($volName =~ m/$volDataNoHSR/)) or ( ((-e $strSnapshotLocation) or (-e $strSnapshotLocation2)) and ($volName =~ m/$volSharedNoHSR/))) {

              $strSSHCmd = "volume snapshot create -volume $volName -snapshot $strSnapshotPrefix\.$date\.recent -snapmirror-label $strSnapshotCustomerLabel -comment $strHANABackupID" ;

          } elsif ( ((-e $strSnapshotLocation) or (-e $strSnapshotLocation2)) and ($volName !~ m/$volDataNoHSR/)) {
              print color('bold magenta');
              logMsg( $LOG_CRIT, "Skipping $volName as it was determined to be a non-active HSR Volume." );
              logMsg( $LOG_CRIT, "If this volume is not part of an HSR setup, please contact Microsoft Operations for assistance." );
              print color('reset');
              next;
          } else {
              logMsg( $LOG_WARN, "HANA snapshot was not successful.");
              logMsg( $LOG_WARN, "Please verify HANA snapshot status in Backup Catalog in HANA Studio.");
              runHANACloseSnapshot();
              runExit($exitWarn);
          }
        }

        if ($strBackupType eq "logs") {

            my $volLogNoHSR = $strHANASID."_".$strTenantNumber;
            logMsg($LOG_INFO, "No HSR Volume: ".$volLogNoHSR);
            if ( ($volName =~ m/$hostname/) or ($volName =~ m/$volLogNoHSR/) ) {

                $strSSHCmd = "volume snapshot create -volume $volName -snapshot $strSnapshotPrefix\.$date\.recent -snapmirror-label $strSnapshotCustomerLabel" ;

            } else {
              print color('bold magenta');
              logMsg( $LOG_CRIT, "Skipping $volName as it was determined to be a non-active HSR Log Backups Volume." );
              logMsg( $LOG_CRIT, "If this volume is not part of an HSR setup, please contact Microsoft Operations for assistance." );
              print color('reset');
              next;
            }
        }
        if ($strOSBackupType eq "TYPEI" or $strOSBackupType eq "TYPEII") {
          $strSSHCmd = "volume snapshot create -volume $volName -snapshot $strSnapshotPrefix\.$date\.recent -snapmirror-label $strSnapshotCustomerLabel" ;
        }
        my @out = runSSHCmd( $strSSHCmd );
		    if ( $? ne 0 ) {
			       logMsg( $LOG_WARN, "Snapshot creation command '" . $strSSHCmd . "' failed: $?" );
             logMsg( $LOG_WARN, "Please try script again in a few minutes. If problem still persists, contact Microsoft Operations");
        } else {
          print color('bold green');
          logMsg( $LOG_CRIT, "Snapshot created successfully for volume $volName." );
          print color('reset');
        }
    }
}


#
# Name: runGetSnapshotsByVolume()
# Func: Obtains the list of snapshots associated with each volume
#

sub runGetSnapshotsByVolume
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
print color('reset');
		my $i = 0;

		logMsg( $LOG_INFO, "Collecting set of snapshots for each volume hosting HANA matching pattern *$strHANASID* ..." );
		foreach my $volName ( @volLocations ) {
				my $j = 0;
				$snapshotLocations[$i][0][0] = $volName;
				my $strSSHDiagCmd = "volume snapshot show -volume $volName -fields snapshot,record-owner";
        my @out = runSSHDiagCmd( $strSSHDiagCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_WARN, "Running '" . $strSSHDiagCmd . "' failed: $?" );
            logMsg( $LOG_WARN, "Please verify that the testStorageSnapshot script was executed and not executed the removeTestStorageSnapshot.pl script yet. It is a required script before executing this script.");
            logMsg( $LOG_WARN, "If testStorageSnapshot was successful, please try again in a few minutes. ");
            logMsg( $LOG_WARN, "If issue persists, please contact Microsoft Operations for support");
            runExit($exitWarn);
				}
				my $listnum = 0;
				$j=1;
				my $count = $#out-1;
				foreach my $k ( 0 ... $count ) {
							#logMsg($LOG_INFO, $item)


							if ( $listnum >= 3) {

							     my @strSubArr = split( /,/, $out[$k] );
							     my $strSub = $strSubArr[$#strSubArr-2];
                   my $strRecordOwner = $strSubArr[$#strSubArr-1];
                   $snapshotLocations[$i][$j][0] = $strSub;
                   $snapshotLocations[$i][$j][1] = $strRecordOwner;
                   $j++;
              }
              $listnum++;
        }
				$i++;
		}
}

#
# Name: runRemoveOlderSnapshots
# Func: Removes snapshot equal to $numKeep during normal execution or removes all snapshots with higher index than customer input of
# retention number in $numKeep as scipt input if customer reduces retention number with the two exceptions: 1. the snapshot is less than 10
# minutes old.  Snapshots that are less than 10 minutes old run the risk of being used as the foundation for the replica and may not be
# removed. 2. Snapshots that are used as foundation for a clone cannot be removed otherwise it creates issues with commonality of snapshots
# between locations.
#

sub runRemoveOlderSnapshots
{

  print color('bold cyan');
	logMsg($LOG_INFO, "**********************Rotating snapshot numbering to allow new snapshot**********************");
  print color('reset');
  my $checkSnapshotResult = "";
		# let's go through all the Filer and volume paths, rotating snapshots for each
	for my $i (0 .. $#snapshotLocations) {


    my $aref = $snapshotLocations[$i];
    my $arraySize = $#{$aref} +1 ;
    my $j;
    if ($arraySize <= $numSnapshotCount) {
        $j = $arraySize;
    } else {
        $j = $numSnapshotCount;
    }
		# get the SVM and volume name(s)
		my $volName = $snapshotLocations[$i][0][0];
		my $checkSnapshotResult;
		# iterate through all the snapshots
		logMsg( $LOG_INFO, "Rotating older snapshots named $strSnapshotPrefix.$j on $snapshotLocations[$i][0][0] ..." );

		while ( $j >= $numKeep ) {

			$checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotPrefix\.$j" );

			if ( $checkSnapshotResult ne "0") {

				my @strSnapSplit = split(/\./, $checkSnapshotResult);
				if ($strSnapSplit[1] ne ""){
          my $snapshotTimeStamp = $strSnapSplit[1];
          my $snapshotName = "$strSnapSplit[0]\.$strSnapSplit[1]\.$j";
          my $checkSnapshotAge = runCheckSnapshotAge($snapshotTimeStamp);
          my $lockedSnapshot = runCheckSnapshotLocked($volName, $snapshotName);
               if ($checkSnapshotAge and !$lockedSnapshot) {
						        my $strSSHCmd = "volume snapshot delete -volume $volName -snapshot $snapshotName";
						        my @out = runSSHCmd( $strSSHCmd );
						        if ( $? ne 0 ) {

                          print color('bold cyan');
                          logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?. ");
                          logMsg( $LOG_WARN, "Please try again in a few minutes. If issue persists, please contact Microsoft Operations.");
                          print color('reset');
                      }
					        } elsif (!$checkSnapshotAge) {
                        print color('bold red');
                      logMsg( $LOG_WARN, "Snapshot aged less than 10 minutes... cannot delete. Stopping execution." );
                      logMsg( $LOG_WARN, "Snapshots are checked for replication every 10 minutes.  You cannot delete a snapshot that the latest replication is based upon.");
                      logMsg( $LOG_WARN, "Either wait 10 minutes so that the replication is no longer based on the previously created snapshot or contact Microsoft Operations.");
                      print color('reset');
                      runExit($exitWarn);
					        } else {
                      print color('bold cyan');
                      logMsg( $LOG_CRIT, "Snapshot cloned in DR location.  Clone must be removed before snapshot is deleted. Rotating Snapshot to higher value than $numKeep temporarily.");
                      print color('reset');
                      my $z = $j+1;
                      my $strSSHCmd = "volume snapshot rename -volume $volName -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.$j -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.$z";
              				my @out = runSSHCmd( $strSSHCmd );
              				if ( $? ne 0 ) {
              					logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
              				}
                  }
				    }
        }
				$j--;
			}
		}
    #if $numkeep equals zero then the script assumes it was in error.
    if ($numKeep eq '0') {
      runExit($exitWarn);
    }
}

#
# Name: runCheckSnapshotAge
# Func: Determines how old snapshot is versus current time of host
#

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

  if ((str2time($currentT)-str2time($t))>600) {
			return 1;
	} else {
			return 0;
	}
}

#
# Name: runCheckSnapshotLocked
# Func: Determines if a snapshot has been used a clone in a DR location.  If clones start becoming process in Production, then this must be
# updated to check for them here as well.
#

sub runCheckSnapshotLocked {


    my $volName = shift;
    my $snapshotName = shift;

    print color('bold cyan');
    logMsg($LOG_INFO,"Checking status of volume $volName and snapshot $snapshotName");
    print color('reset');

    my $i = 0;
    my $j = 0;

    while ($snapshotLocations[$i][$j][0] ne $volName) {
      logMsg($LOG_INFO, "volume: $volName searched: ".$snapshotLocations[$i][$j][0]);
      $i++;
      if ($i eq $#snapshotLocations) {
        return 0;
      }
    }

    my $aref = $snapshotLocations[$i];
    my $arraySize = $#{$aref}+1;
    while ($snapshotLocations[$i][$j][0] ne $snapshotName) {

      $j++;
      if ($j eq $arraySize) {
        return 0;
      }
    }

    #now that we have found the matching volume and snapshot, need to verify status of snapshot
    if ($snapshotLocations[$i][$j][1] =~ m/snapmirror/) {

        print color('bold cyan');
        logMsg($LOG_INFO,"Snapshot $snapshotName of volume $volName has record owner of $snapshotLocations[$i][$j][1]");
        print color('reset');
        return 1;
    } else {
        print color('bold cyan');
        logMsg($LOG_INFO,"Snapshot $snapshotName of volume $volName has no record owner");
        print color('reset');
        return 0;
    }
}

#
# Name: runRotateLockedSnapshotsDown
# Func: Similar in functionality to runRotateSnapshots but for those snapshots with index greater than $numKeep.  Ensures that snapshot index is
# rotated down in the event of a gap exists between in the index between locked snapshots. For example. customer makes 3 clones and has retention
# of 10 resulting in snapshots with index .10, .11, .12.  After sometime customer has Microsoft Operations delete clone associated with snapshot index
# .11.  Snapshot index .11 is now removed and snapshot with index .12 is rotated down to .11.
#

sub runRotateLockedSnapshotsDown {

  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Rotating locked snapshots down to minimize number**********************");
  print color('reset');
  my $rotateIndex;
  my $j;
  my $k;
  my $checkSnapshotResult = "";
  	# let's go through all the Filer and volume paths, rotating snapshots for each
  for my $i (0 .. $#snapshotLocations) {
  		# set up our loop counters
      my $aref = $snapshotLocations[$i];
      my $arraySize = $#{$aref} +1 ;

      # get the SVM and volume name(s)
      my $volName = $snapshotLocations[$i][0][0];
      my $checkSnapshotResult;
      $k = $numKeep+1;
      #to get right index, verifying whether snapshot corresponding to $numKeep was removed or not.
      $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotPrefix\.$numKeep" );
      logMsg($LOG_INFO, "Check Snapshot result for $numKeep: $checkSnapshotResult");
      if ($checkSnapshotResult ne "0") {
        logMsg($LOG_INFO,"Snapshot ".$strSnapshotPrefix.".".$numKeep." was previously locked ");
        $j = $k;

      } else {

        logMsg($LOG_INFO,"Snapshot ".$strSnapshotPrefix.".".$numKeep." was not previously locked ");
        $j = $k;
        $k = $numKeep;

      }
  		# iterate through all the snapshots
  		logMsg( $LOG_INFO, "Rotating snapshots named $strSnapshotPrefix.# on $volName ..." );
      logMsg($LOG_INFO, "J: $j K: $k NumSnapshotCount: $numSnapshotCount");
  		while ( $j <= $numSnapshotCount ) {

        $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotPrefix\.$j" );
        logMsg($LOG_INFO, "Check Snapshot result for $j: $checkSnapshotResult");
  			if ( $checkSnapshotResult ne "0") {
          Time::HiRes::sleep (0.5+rand(0.5));
  				my @strSnapSplit = split(/\./, $checkSnapshotResult);
  				my $strSSHCmd = "volume snapshot rename -volume $volName -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.$j -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.$k";
  				my @out = runSSHCmd( $strSSHCmd );
  				if ( $? ne 0 ) {
  					logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
            logMSg( $LOG_WARN, "Unable to rename snapshot. Either the snapshot name already exists or there was an error communicating with the storage.");
            logMsg( $LOG_WARN, "Please try again in a few minutes. If the problem persists, contact Microsoft Operations");
  				}
          $k++;
        }

  			$j++;
  		}
  	}
}

#
# Name: runCountSnapshotPrefix()
# Func: Counts number of snapshots for volume that matches customer input of snapshotPrefix to potentially reduce iterations
#

sub runCountSnapshotPrefix {

  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Counting number of Snapshots that match customer provided snapshot prefix**********************");
  print color('reset');
  logMsg($LOG_INFO, "Snapshot Count: $numSnapshotCount");
  for my $i (0 .. $#snapshotLocations) {

     my $aref = $snapshotLocations[$i];
     for my $j (1 .. $#{$aref}) {

      my @strSnapSplit = split(/\./, $snapshotLocations[$i][$j][0]);
      if (!defined($strSnapSplit[2])) { next; }
      logMsg($LOG_INFO, "snapshot: $snapshotLocations[$i][$j][0] snapshot prefix: $strSnapSplit[0] number: $strSnapSplit[2] prefix: $strSnapshotPrefix");
      if ($strSnapSplit[0] eq $strSnapshotPrefix) {
        logMsg($LOG_INFO, "Snapshot Matched");
        logMsg($LOG_INFO, "index: $strSnapSplit[2]   count: $numSnapshotCount ");
        my $snapshotIndex = $strSnapSplit[2];
        if ($snapshotIndex ne "recent") {
          if ($snapshotIndex >= $numSnapshotCount) {
            $numSnapshotCount = $strSnapSplit[2];
          }
        }
      }
    }
  }
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Snapshot Count: $numSnapshotCount**********************");
  print color('reset');

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
# Name: runClearVolumeLocations()
# Func: Clears the list of snapshots by volume so that updated snapshot list can be used
#

sub runClearSnapshotLocations
{
print color('bold cyan');
  logMsg($LOG_INFO, "**********************Clearing snapshot list**********************");
print color('reset');
  undef @snapshotLocations;
}

#
# Name: displayArray()
# Func: Displays list of snapshots by volume
#

sub displayArray
{
print color('bold cyan');
logMsg($LOG_CRIT, "**********************Displaying Snapshots by Volume**********************");
print color('reset');
         for my $i (0 .. $#snapshotLocations) {
                my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref}) {

                         if ($j eq 0) {
                           print color('bold cyan');
                           logMsg($LOG_CRIT,$snapshotLocations[$i][$j][0]);
                           print color('reset');
                        }  else {
                            logMsg($LOG_CRIT,$snapshotLocations[$i][$j][0]);
                        }

                 }
         }

}

#
# Name: runPrintFile()
# Func: Prints contents of $LOG_INFO, $LOG_CRIT, and $LOG_WARN to log file within snanshotLogs directory
#

sub runPrintFile
{
	my $myLine;
	my $date = localtime->strftime('%Y-%m-%d_%H%M');
  if (!defined($strSnapshotPrefix)) {
    $outputFilename = "azure_backup.$date.txt";
  } else {
    $outputFilename = "azure_backup.$strSnapshotPrefix.$date.txt";
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
logMsg($LOG_CRIT,"Executing Azure Hana Backup Script, Version $version");

if (!defined($ARGV[0])){
  logMsg( $LOG_WARN, "Please enter argument as either hana, logs, or boot." );
  runExit($exitWarn);
}

if ($strBackupType ne "hana" and $strBackupType ne "logs" and $strBackupType ne "boot") {
	logMsg( $LOG_WARN, "Please enter argument as either hana, logs, or boot." );
	runExit($exitWarn);
}
logMsg($LOG_CRIT,"Executing ".$strBackupType." backup.");
if (($strBackupType eq "hana" or $strBackupType eq "logs") and (!defined($ARGV[1]) or !defined($ARGV[2]) or !defined($ARGV[3]))) {

  logMsg( $LOG_WARN, "Please enter argument as either (hana or logs) <Customer Snapshot Label> <frequency> <retention> (verbose)" );
  runExit($exitWarn);
}



if ($strBackupType eq "boot" and (($ARGV[1] ne "TYPEI" and $ARGV[1] ne "TYPEII") or $ARGV[1] eq "" or $ARGV[2] eq "" or $ARGV[3] eq "" or $ARGV[4] eq "")) {
	logMsg( $LOG_WARN, "Please enter argument as either boot <TYPEI or TYPEII> <Customer Snapshot Label> <frequency> <retention> (verbose)" );
	runExit($exitWarn);
}

if($strBackupType eq "boot" and defined($ARGV[5])) {
      if ($ARGV[5] eq "verbose") {
        $verbose = 1;
      } else {
	      logMsg( $LOG_WARN, "Please enter argument as either boot <TYPEI or TYPEII> <Customer Snapshot Label> <frequency> <retention> (verbose)" );
        runExit($exitWarn);
      }
}

if(($strBackupType eq "hana" or $strBackupType eq "logs") and defined($ARGV[4])) {
      if ($ARGV[4] eq "verbose") {
        $verbose = 1;
      }
}


#read and store each line of HANABackupCustomerDetails to fileHandle
runOpenParametersFiles();

#verify each line is expected based on template, otherwise throw error.
runVerifyParametersFile();

#add Parameters to usable array customerDetails
runGetParameterDetails();

#verify all required details entered for each SID
runVerifySIDDetails();

if ($strBackupType eq "hana" or $strBackupType eq "logs" ) {

  for my $i (0 .. $numSID) {

    if ($arrCustomerDetails[$i][0] and ($arrCustomerDetails[$i][0] ne "Skipped" and $arrCustomerDetails[$i][0] ne "Omitted")) {
       $strHANASID = $arrCustomerDetails[$i][0];
       $strHANASIDUC = uc $strHANASID;
       #set up our variables for each SID based on backup type and HANA enviroment.
       print color('bold blue');
       logMsg($LOG_CRIT, "Executing ".$strBackupType." Snapshots for $strHANASID");
       print color('reset');
       #customer input variables in HANABackupCustomerDetails.txt

       $strUser = $arrCustomerDetails[$i][1];
       $strSVM = $arrCustomerDetails[$i][2];

       #customer provided arguments to script
       $strSnapshotPrefix = $ARGV[1];

       if ( not $strSnapshotPrefix =~ /^[a-zA-Z0-9_-]*$/  ) {
                #only want Alpha-numeric, "-", & "_" characters in the prefix
                logMsg( $LOG_WARN, "Customer Snapshot Label '".$strSnapshotPrefix."' not allowed" );
                logMsg( $LOG_WARN, "Please use alpha-numeric (A-Za-z0-9), - (dash), and _ underscore characters only" );
                runExit($exitWarn);
      }

       $strSnapshotCustomerLabel = lc $ARGV[2];
       $numKeep = $ARGV[3];
       if ( not $numKeep =~ /^[0-9]*$/  ) {
                #only want Alpha-numeric, "-", & "_" characters in the prefix
                logMsg( $LOG_WARN, "Retention Value must be number only.".$numKeep." is not allowed" );
                runExit($exitWarn);
       }
       if ($numKeep le 0 or $numKeep gt 250) {
         #numKeep in range 1 to 250
         logMsg( $LOG_WARN, "A Customer provided retention value less than 1 or greater than 250 is not allowed" );
         runExit($exitWarn);
       }

       if (($strSnapshotCustomerLabel ne "15min") and ($strSnapshotCustomerLabel ne "3min")) {
          #current accepted snapmirror labels (frequency) are 15min for data, 3min for log backups
          logMsg( $LOG_WARN, "A frequency of $strSnapshotCustomerLabel is not an acceptable frequency." );
          logMsg( $LOG_WARN, "For HANA backups and boot backups, please use 15min");
          logMsg( $LOG_WARN, "For log backups, please use 3min");
          runExit($exitWarn);
       }

       $strHANANumInstance = $arrCustomerDetails[$i][3];
       $strHANAAdmin = $arrCustomerDetails[$i][4];
       $strHANAStatusCmdV1 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "\s"';
       $strHANAStatusCmdV2 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "\s"';

       $strHANAStatusCmdV1 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "\s"';
       $strHANAStatusCmdV2 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "\s"';
       $strHANACreateSnapCmdV1 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data create snapshot"';
       $strHANACreateSnapCmdV2 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "backup data for full system create snapshot"';
       $strHANABackupIDRequestV1 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin .' "'. $strHANAIDRequestString.'"' ;
       $strHANABackupIDRequestV2 = './hdbsql -n '.$strPrimaryHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U ' . $strHANAAdmin .' "'. $strHANAIDRequestString.'"' ;

    } else {
      logMsg($LOG_CRIT, "No data entered for SID".($i+1)."  Skipping!!!");
      next;
    }
#Before executing the rest of the script, all HANA nodes must be accessible for scale-out
    runCheckHANAVersion();
    runCheckHANAStatus();

  # get volume(s) to take a snapshot of
  runGetVolumeLocations();

  #get snapshots by volume and place into array
  runGetSnapshotsByVolume();
  #displayArray();

  #counts the maximum snapshot number for customer requested snapshot prefix
  runCountSnapshotPrefix();

  #if customer reduces number of snapshots as argument, this goes through and removes all that are above that number, also rotates up any snapshots that are locked
  runRemoveOlderSnapshots();

  #clears snapshot locations from multi-linked array so new can be added
  #now that snapshots older than numbkeep have been removed
  runClearSnapshotLocations();

  #get snapshots again.
  runGetSnapshotsByVolume();
  #displayArray();

  #counts the maximum snapshot number for customer requested snapshot prefix
  runCountSnapshotPrefix();

  # get rid of the recent snapshot (if it exists)
  runRemoveRecentSnapshot();

  #if argument entered is for hana backup, then execute hana snapshot and verify it exists
  if ($strBackupType eq "hana") {
    # execute the HANA create snapshot command
    runCreateHANASnapshot();

    #verify status of HANA snapshot just created
    runCheckHANASnapshotStatus();

  }

  # execute the backup
  runCreateStorageSnapshot();

  # execute the HANA drop snapshot command
  if ($strBackupType eq "hana") {
  #execute the HANA close snapshot command
      runHANACloseSnapshot();

  }
  # get rid of the oldest snapshot (in case of some wierd failure last time)
  runRemoveOldestSnapshot("1");

  # rotate snapshots before we move on to quiescing the VMs
  runRotateSnapshots();

  #clears snapshot locations from multi-TYPEInked array so new can be added
  runClearSnapshotLocations();

  #gets snapshots again after creating new storage snapshots and rotating existing snapshots
  runGetSnapshotsByVolume();
  #displayArray();

  # get rid of the oldest snapshot (again, this time because we need to)
  runRemoveOldestSnapshot("2");

  #clears snapshot locations from multi-linked array so new can be added
  runClearSnapshotLocations();

  #gets snapshots again after creating new storage snapshots and rotating existing snapshots
  runGetSnapshotsByVolume();
  #displayArray();

  #rotate snapshots that are locked down to correct position above $numKeep.
  runRotateLockedSnapshotsDown();

  #clears snapshot locations from multi-linked array so new can be added
  runClearSnapshotLocations();

  #gets snapshots again after creating new storage snapshots and rotating existing snapshots
  runGetSnapshotsByVolume();
  #displayArray();

  # rename the recent snapshot
  runRenameRecentSnapshot();

  #clears snapshot locations from multi-linked array so new can be added
  runClearSnapshotLocations();

  #gets snapshots again after creating new storage snapshots and rotating existing snapshots
  runGetSnapshotsByVolume();
  displayArray();

  runClearSnapshotLocations();
  runClearVolumeLocations();
  }
}

if ($strBackupType eq "boot" ) {

  #customer input variables in HANABackupCustomerDetails.txt
  $strUser = $arrCustomerDetails[0][1];
  $strSVM = $arrCustomerDetails[0][2];

  #customer provided arguments to script
  $strOSBackupType = $ARGV[1];
  $strSnapshotPrefix = $ARGV[2];
  $strSnapshotCustomerLabel = $ARGV[3];
  $numKeep = $ARGV[4];

  if ($strOSBackupType eq "TYPEII") {
    $strHANASID = $strPrimaryHANAServerName;
  } else {
    $strHANASID = "boot";
  }



# get volume(s) to take a snapshot of
runGetVolumeLocations();

#get snapshots by volume and place into array
runGetSnapshotsByVolume();
#displayArray();

#if customer reduces number of snapshots as argument, this goes through and removes all that are above that number
runRemoveOlderSnapshots();

#clears snapshot locations from multi-linked array so new can be added
#now that snapshots older than numbkeep have been removed
runClearSnapshotLocations();

#get snapshots again.
runGetSnapshotsByVolume();
#displayArray();

# get rid of the recent snapshot (if it exists)
runRemoveRecentSnapshot();

if ($strOSBackupType eq "TYPEII") {
  # execute the HANA create snapshot command
  runTYPEIIBackup();
}

# execute the backup
runCreateStorageSnapshot();

# get rid of the oldest snapshot (in case of some wierd failure last time)
runRemoveOldestSnapshot("1");

# rotate snapshots before we move on to quiescing the VMs
runRotateSnapshots();

#clears snapshot locations from multi-TYPEInked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
#displayArray();

# get rid of the oldest snapshot (again, this time because we need to)
runRemoveOldestSnapshot("2");

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
#displayArray();

#rotate snapshots that are locked down to correct position above $numKeep.
runRotateLockedSnapshotsDown();

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
#displayArray();

# rename the recent snapshot
runRenameRecentSnapshot();

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
displayArray();
}

# if we get this far, we can exit cleanly
logMsg( $LOG_CRIT, "Command completed successfully." );



# time to exit
runExit( $ERR_NONE );
