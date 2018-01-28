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
use Time::HiRes;
use Term::ANSIColor;
#number of allowable SIDs. Number entered is one less than actual.. i.e if allowing 4 SIDs, then 3 is entered
my $numSID = 9;
my $detailsStart = 13;
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
my $strBackupType = $ARGV[0];

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
my $strHANAServerName;
my $strHANAServerIPAddress;
my $filename = "HANABackupCustomerDetails.txt";
my $strHANAInstance;
my @arrCustomerDetails;
my $numKeep;
my $strSnapshotCustomerLabel;
my $strSnapshotPrefix;
my $strUser;
my $strSVM;
my $strHANANumInstance;
my $strHANAAdmin;
my $strOSBackupType = "none";
my $cloneSnapshot = 0;
my $numSnapshotCount = 0;;

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
my $sshCmd = '/usr/bin/ssh';
my $strHANASID;
my $hanaSnapshotSuccess = qq('Storage snapshot successful');
my $strHANAIDRequestString = "select BACKUP_ID from M_BACKUP_CATALOG where ENTRY_TYPE_NAME = 'data snapshot' and STATE_NAME = 'prepared'";
my $strHANAStatusCmdV1;
my $strHANAStatusCmdV2;
my $strHANACreateCmdV1;
my $strHANACreateCmdV2;
my $strHANABackupIDRequestV1;
my $strHANABackupIDRequestV2;

my $strHANACloseCmdSuccess;
my $strHANACloseCmdV1;
my $strHANACloseCmdV2;

my $strHANAVersion;

#my $strHANACloseCmdNoSuccess = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data close snapshot backup_id '.$strHANABackupID . ' UNSUCCESSFUL "DO NOT USE - Storage Snapshot Unsuccessful!" "'   ;
#my $strHANADeleteCmd = "";

my $arrSnapshot = "";
my $outputFilename = "";
my @snapshotLocations;
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
          logMsg($LOG_INFO,"HANA Version: $strHANAVersion for SID: $strHANASID");
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

#
# Executes rear tool for TYPEII OS Backups
#
sub runTYPEIIBackup() {

logMsg($LOG_INFO,"Creating backup of ".$strHANAInstance." using rear tool.");


      my $strREARBackup = "rear -v mkbackup";
      my @out = runShellCmd( $strREARBackup );
      if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "Server backup command $strREARBackup failed." );
					logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
					exit;
				} else {
					logMsg( $LOG_INFO, "Server Backup created successfully." );
			}



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
  if ($strOSBackupType eq "TYPEI") {
     logMsg($LOG_INFO, "**********************Getting list of volumes of boot volumes**********************");
     $strSSHCmd = "volume show -volume *boot* -type RW -fields volume";
  }
  if ($strBackupType eq "logs") {
    logMsg($LOG_INFO, "**********************Getting list of volumes that match HANA instance specified**********************");
	  logMsg( $LOG_INFO, "Collecting set of volumes hosting HANA matching pattern *$strHANAInstance* ..." );
	  $strSSHCmd = "volume show -volume *log_backups_".$strHANAInstance."* -type RW -fields volume";
  }

  if ($strOSBackupType eq "TYPEII") {
     logMsg($LOG_INFO, "**********************Getting list of volumes of boot volumes**********************");
     $strSSHCmd = "volume show -volume *".$strHANAServerName."_os* -type RW -fields volume";
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
# Func: Rotate the snapshots in a loop
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



    if ($arraySize <= $numKeep) {
        $rotateIndex = $arraySize;

    } else {
        $rotateIndex = $numKeep;
    }

    my $j = $rotateIndex;
		my $k = $rotateIndex - 1;

    print "j: $j  k: $k\n";
		# get the SVM and volume name(s)
		my $volName = $snapshotLocations[$i][0][0];
		my $checkSnapshotResult;
		# iterate through all the snapshots
		logMsg( $LOG_INFO, "Rotating snapshots named $strSnapshotCustomerLabel.# on $snapshotLocations[$i][0][0] ..." );

		while ( $k >= 0 ) {

      $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotCustomerLabel\.$k" );

			if ( $checkSnapshotResult ne "0") {
        Time::HiRes::sleep (0.5+rand(0.5));
				my @strSnapSplit = split(/\./, $checkSnapshotResult);
        logMsg($LOG_INFO, "Renaming Snapshot ".$strSnapSplit[0].".".$k." to ".$strSnapSplit[0].".".$j);
				my $strSSHCmd = "volume snapshot rename -volume $volName -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.$k -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.$j";
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
    my $snapshotName = "$strSnapshotCustomerLabel\.$numKeep";

    my $checkSnapshotResult = runCheckIfSnapshotExists( $volName, $snapshotName );
    my $lockedSnapshot = runCheckSnapshotLocked($volName,$checkSnapshotResult);
    print "Result: $checkSnapshotResult   Locked: $lockedSnapshot\n";
    if ( $checkSnapshotResult eq "0") {

			logMsg( $LOG_INFO, "Oldest snapshot " . $strSnapshotCustomerLabel . "." . $numKeep . " does not exist on $snapshotLocations[$i][0][0]." );

		} elsif ($lockedSnapshot ne "0") {

      logMsg( $LOG_INFO, "Snapshot $strSnapshotCustomerLabel\.$numKeep on $volName is locked and will be kept at index: $numKeep");

    } else {
      logMsg( $LOG_INFO, "Removing oldest snapshot $strSnapshotCustomerLabel\.$numKeep on $snapshotLocations[$i][0][0] on SVM $strSVM ..." );
			my $strSSHCmd = "volume snapshot delete -volume $snapshotLocations[$i][0][0] -snapshot $checkSnapshotResult";
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
print color('bold cyan');
logMsg($LOG_INFO, "**********************Deleting existing *.recent snapshot**********************");
logMsg($LOG_INFO, "**********************Failures are allowed if *.recent was properly cleaned up last backup**********************");
print color('reset');
	for my $i (0 .. $#snapshotLocations) {
		# let's make sure the snapshot is there first
    my $volName = $snapshotLocations[$i][0][0];
    my $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotCustomerLabel\.recent");
		if ($checkSnapshotResult eq "0") {
			logMsg( $LOG_INFO, "Recent snapshot $strSnapshotCustomerLabel\.recent does not exist on $snapshotLocations[$i][0][0]." );
		} else {
			# delete the recent snapshot
			logMsg( $LOG_INFO, "Removing recent snapshot $strSnapshotCustomerLabel\.recent on $snapshotLocations[$i][0][0] on SVM $strSVM ..." );
			logMsg($LOG_INFO, $checkSnapshotResult);
			my $strSSHCmd = "volume snapshot delete -volume $snapshotLocations[$i][0][0] -snapshot $checkSnapshotResult";

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
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Renaming *.recent snapshot to *.0**********************");
  print color('reset');
  for my $i (0 .. $#snapshotLocations) {
		logMsg( $LOG_INFO, "Renaming snapshot $strSnapshotCustomerLabel\.recent to $strSnapshotCustomerLabel\.0 for $snapshotLocations[$i][0][0] on SVM $strSVM ..." );
		my $checkSnapshotResult = runCheckIfSnapshotExists( $snapshotLocations[$i][0][0], "$strSnapshotCustomerLabel\.recent");
		if ($checkSnapshotResult eq "0") {
			logMsg( $LOG_INFO, "Recent snapshot $strSnapshotCustomerLabel\.recent does not exist on $snapshotLocations[$i][0][0]." );
		} else {
				my @strSnapSplit = split(/\./, $checkSnapshotResult);
				#logMsg($LOG_INFO,$checkSnapshotResult);
				my $strSSHCmd = "volume snapshot rename -volume $snapshotLocations[$i][0][0] -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.recent -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.0";
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
      print color('bold cyan');
      logMsg($LOG_INFO, "**********************Creating HANA snapshot**********************");
      print color('reset');
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
          print color ('bold green');
          logMsg( $LOG_INFO, "HANA snapshot created successfully." );
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
      logMsg($LOG_INFO, "**********************Checking for HANA snapshot and obtaining ID**********************");
      print color('reset');
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
      print color('bold cyan');
      logMsg($LOG_INFO, "**********************Closing HANA snapshot**********************");
      print color('reset');
      # Delete the HANA database snapshot
      if ($strHANAVersion eq 1) {
        $strHANACloseCmdV1 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data close snapshot backup_id '. $strHANABackupID . ' SUCCESSFUL '.$hanaSnapshotSuccess.qq(");
        $strHANACloseCmd = $strHANACloseCmdV1;
      }
      if ($strHANAVersion eq 2) {
        $strHANACloseCmdV2 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U ' . $strHANAAdmin . ' "backup data for full system close snapshot backup_id '. $strHANABackupID . ' SUCCESSFUL '.$hanaSnapshotSuccess.qq(");
        $strHANACloseCmd = $strHANACloseCmdV2;
      }
      logMsg( $LOG_INFO, "Deleting the HANA snapshot with command: \"$strHANACloseCmd\" ..." );
      my @out = runShellCmd( $strHANACloseCmd );
      if ( $? ne 0 ) {
          logMsg( $LOG_WARN, "HANA snapshot deletion command '" . $strHANACloseCmd . "' failed: $?" );
      } else {
          print color('bold green');
          logMsg( $LOG_INFO, "HANA snapshot closed successfully." );
          print color('reset');
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
print color('bold cyan');
logMsg($LOG_INFO, "**********************Creating Storage snapshot**********************");
print color('reset');
    my $strSSHCmd;
    for my $i (0 .. $#snapshotLocations) {
		# take the recent snapshot with SSH
		logMsg( $LOG_INFO, "Taking snapshot $strSnapshotCustomerLabel\.recent for $snapshotLocations[$i][0][0] ..." );
#storage command necessary to create storage snapshot, others items to include: snapmirror-label matching snapshot type/frequency and HANA snapshot backup id matching as comment
		my $date = localtime->strftime('%Y-%m-%d_%H%M');
    if ($strBackupType eq "hana") {
      $strSSHCmd = "volume snapshot create -volume $snapshotLocations[$i][0][0] -snapshot $strSnapshotCustomerLabel\.$date\.recent -snapmirror-label $strSnapshotPrefix -comment $strHANABackupID" ;
    }
    if ($strOSBackupType eq "TYPEI" or $strBackupType eq "logs" or $strOSBackupType eq "TYPEII") {
      $strSSHCmd = "volume snapshot create -volume $snapshotLocations[$i][0][0] -snapshot $strSnapshotCustomerLabel\.$date\.recent -snapmirror-label $strSnapshotPrefix" ;
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
print color('bold cyan');
logMsg($LOG_INFO, "**********************Adding list of snapshots to volume list**********************");
print color('reset');
		my $i = 0;

		logMsg( $LOG_INFO, "Collecting set of snapshots for each volume hosting HANA matching pattern *$strHANAInstance* ..." );
		foreach my $volName ( @volLocations ) {
				my $j = 0;
				$snapshotLocations[$i][0][0] = $volName;
				my $strSSHDiagCmd = "volume snapshot show -volume $volName -fields snapshot,record-owner";
        my @out = runSSHDiagCmd( $strSSHDiagCmd );
				if ( $? ne 0 ) {
						logMsg( $LOG_WARN, "Running '" . $strSSHDiagCmd . "' failed: $?" );
						return( 0 );
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

sub displayArray
{
print color('bold cyan');
logMsg($LOG_INFO, "**********************Displaying Snapshots by Volume**********************");
print color('reset');
         for my $i (0 .. $#snapshotLocations) {
                my $aref = $snapshotLocations[$i];
                for my $j (0 .. $#{$aref}) {

                         logMsg($LOG_INFO,$snapshotLocations[$i][$j][0]);
                 }
         }

}


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
			logMsg( $LOG_INFO, "Rotating older snapshots named $strSnapshotCustomerLabel.$j on $snapshotLocations[$i][0][0] ..." );

			while ( $j >= $numKeep ) {

				$checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotCustomerLabel\.$j" );

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
                          logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?. Please contact Microsoft Operations for support." );
                          print color('reset');
                      }
					        } elsif (!$checkSnapshotAge) {
                        print color('bold red');
                      logMsg( $LOG_WARN, "snapshot aged less than 10 minutes... cannot delete. Stopping execution." );
                      print color('reset');
                      runExit($exitWarn);
					        } else {
                        print color('bold cyan');
                      logMsg( $LOG_INFO, "Snapshot cloned in DR location.  Clone must be removed before snapshot is deleted. Rotating Snapshot to higher value than $numKeep temporarily.");
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


sub runCheckSnapshotLocked {


    my $volName = shift;
    my $snapshotName = shift;

    print color('bold cyan');
    logMsg($LOG_INFO,"Checking status of volume $volName and snapshot $snapshotName");
    print color('reset');

    my $i = 0;
    my $j = 0;

    while ($snapshotLocations[$i][$j][0] ne $volName) {
      print "volume: $volName searched: ".$snapshotLocations[$i][$j][0];
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
      $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotCustomerLabel\.$numKeep" );
      print "Check Snapshot result for $numKeep: $checkSnapshotResult\n";
      if ($checkSnapshotResult ne "0") {
        logMsg($LOG_INFO,"Snapshot ".$strSnapshotCustomerLabel.".".$numKeep." was previously locked ");
        $j = $k;

      } else {

        logMsg($LOG_INFO,"Snapshot ".$strSnapshotCustomerLabel.".".$numKeep." was not previously locked ");
        $j = $k;
        $k = $numKeep;

      }
  		# iterate through all the snapshots
  		logMsg( $LOG_INFO, "Rotating snapshots named $strSnapshotCustomerLabel.# on $volName ..." );
      print "J: $j K: $k NumSnapshotCount: $numSnapshotCount\n";
  		while ( $j <= $numSnapshotCount ) {

        $checkSnapshotResult = runCheckIfSnapshotExists( $volName, "$strSnapshotCustomerLabel\.$j" );
        print "Check Snapshot result for $j: $checkSnapshotResult\n";
  			if ( $checkSnapshotResult ne "0") {
          Time::HiRes::sleep (0.5+rand(0.5));
  				my @strSnapSplit = split(/\./, $checkSnapshotResult);
  				my $strSSHCmd = "volume snapshot rename -volume $volName -snapshot $strSnapSplit[0]\.$strSnapSplit[1]\.$j -new-name $strSnapSplit[0]\.$strSnapSplit[1]\.$k";
  				my @out = runSSHCmd( $strSSHCmd );
  				if ( $? ne 0 ) {
  					logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
  				}
          $k++;
        }

  			$j++;
  		}
  	}
}

sub runCountSnapshotPrefix {

  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Counting number of Snapshots that match customer provided snapshot prefix**********************");
  print color('reset');

  for my $i (0 .. $#snapshotLocations) {
     my $aref = $snapshotLocations[$i];
     for my $j (1 .. $#{$aref}) {

        my @strSnapSplit = split(/\./, $snapshotLocations[$i][$j][0]);
        print "snapshot: $snapshotLocations[$i][$j][0] snapshot prefix: $strSnapSplit[0] number: $strSnapSplit[2] prefix: $strSnapshotCustomerLabel\n";
        if ($strSnapSplit[0] eq $strSnapshotCustomerLabel) {
              print "Matched\n";
              print "index: $strSnapSplit[2]   count: $numSnapshotCount \n";
              if ($strSnapSplit[2] >= $numSnapshotCount) {
                $numSnapshotCount = $strSnapSplit[2];
              }
        }
    }
  }
  print color('bold cyan');
  logMsg($LOG_INFO, "**********************Snapshot Count: $numSnapshotCount**********************");
  print color('reset');

}

sub runPrintFile
{
	my $myLine;
	my $date = localtime->strftime('%Y-%m-%d_%H%M');
	$outputFilename = "$strSnapshotCustomerLabel.$date.txt";
	my $existingdir = './snapshotLogs';
	mkdir $existingdir unless -d $existingdir; # Check if dir exists. If not create it.
	open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
	foreach $myLine (@arrOutputLines) {
		print $fileHandle $myLine;


	}
	close $fileHandle;
}

##### --------------------- MAIN CODE --------------------- #####
logMsg($LOG_INFO,"Executing Azure HANA Backup Script, Version $version");
if (!defined($ARGV[0])){
  logMsg( $LOG_WARN, "Please enter argument as either hana, logs, or boot." );
  runExit($exitWarn);
}

if ($strBackupType ne "hana" and $strBackupType ne "logs" and $strBackupType ne "boot") {
	logMsg( $LOG_WARN, "Please enter argument as either hana, logs, or boot." );
	runExit($exitWarn);
}
logMsg($LOG_INFO,"Executing ".$strBackupType." backup.");
if (($strBackupType eq "hana" or $strBackupType eq "logs") and ($ARGV[1] eq "" or $ARGV[2] eq "" or $ARGV[3] eq "")) {

  logMsg( $LOG_WARN, "Please enter argument as either (hana or logs) <Customer Snapshot Label> <frequency> <retention>" );
  runExit($exitWarn);
}



if ($strBackupType eq "boot" and (($ARGV[1] ne "TYPEI" and $ARGV[1] ne "TYPEII") or $ARGV[1] eq "" or $ARGV[2] eq "" or $ARGV[3] eq "" or $ARGV[4] eq "")) {
	logMsg( $LOG_WARN, "Please enter argument as either boot <TYPEI or TYPEII> <Customer Snapshot Label> <frequency> <retention>" );
	runExit($exitWarn);
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

       $strHANAInstance = $arrCustomerDetails[$i][0];
       $strHANASID = uc $arrCustomerDetails[$i][0];
       print color('bold blue');
       logMsg($LOG_INFO, "Executing ".$strBackupType." Snapshots for $strHANAInstance");
       print color('reset');
       $strHANAInstance = $arrCustomerDetails[$i][0];
       $strUser = $arrCustomerDetails[$i][1];
       $strSVM = $arrCustomerDetails[$i][2];
       $strSnapshotCustomerLabel = $ARGV[1];
       $strSnapshotPrefix = $ARGV[2];
       $numKeep = $ARGV[3];
       $strHANANumInstance = $arrCustomerDetails[$i][3];
       $strHANAAdmin = $arrCustomerDetails[$i][4];
       $strHANAStatusCmdV1 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "\s"';
       $strHANAStatusCmdV2 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "\s"';

       $strHANAStatusCmdV1 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "\s"';
       $strHANAStatusCmdV2 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "\s"';
       $strHANACreateCmdV1 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "backup data create snapshot"';
       $strHANACreateCmdV2 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U '.$strHANAAdmin.' "backup data for full system create snapshot"';
       $strHANABackupIDRequestV1 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin .' "'. $strHANAIDRequestString.'"' ;
       $strHANABackupIDRequestV2 = './hdbsql -n '.$strHANAServerIPAddress.' -i '.$strHANANumInstance.' -d SYSTEMDB -U ' . $strHANAAdmin .' "'. $strHANAIDRequestString.'"' ;

    } else {
      logMsg($LOG_INFO, "No data entered for SID".($i+1)."  Skipping!!!");
      next;
    }
#Before executing the rest of the script, all HANA nodes must be accessible for scale-out
  if ($strBackupType eq "hana") {
    runCheckHANAVersion();
    runCheckHANAStatus();

  }

  # get volume(s) to take a snapshot of
  runGetVolumeLocations();

  #get snapshots by volume and place into array
  runGetSnapshotsByVolume();
  displayArray();

  #counts the maximum snapshot number for customer requested snapshot prefix
  runCountSnapshotPrefix();

  #if customer reduces number of snapshots as argument, this goes through and removes all that are above that number, also rotates up any snapshots that are locked
  runRemoveOlderSnapshots();

  #clears snapshot locations from multi-linked array so new can be added
  #now that snapshots older than numbkeep have been removed
  runClearSnapshotLocations();

  #get snapshots again.
  runGetSnapshotsByVolume();
  displayArray();

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
  displayArray();

  # get rid of the oldest snapshot (again, this time because we need to)
  runRemoveOldestSnapshot("2");

  #clears snapshot locations from multi-linked array so new can be added
  runClearSnapshotLocations();

  #gets snapshots again after creating new storage snapshots and rotating existing snapshots
  runGetSnapshotsByVolume();
  displayArray();

  #rotate snapshots that are locked down to correct position above $numKeep.
  runRotateLockedSnapshotsDown();

  #clears snapshot locations from multi-linked array so new can be added
  runClearSnapshotLocations();

  #gets snapshots again after creating new storage snapshots and rotating existing snapshots
  runGetSnapshotsByVolume();
  displayArray();

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

  $strUser = $arrCustomerDetails[0][1];
  $strSVM = $arrCustomerDetails[0][2];
  $strOSBackupType = $ARGV[1];
  $strSnapshotCustomerLabel = $ARGV[2];
  $strSnapshotPrefix = $ARGV[3];
  $numKeep = $ARGV[4];

  if ($strOSBackupType eq "TYPEII") {
    $strHANAInstance = $strHANAServerName;
  } else {
    $strHANAInstance = "boot";
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
displayArray();

# get rid of the oldest snapshot (again, this time because we need to)
runRemoveOldestSnapshot("2");

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
displayArray();

#rotate snapshots that are locked down to correct position above $numKeep.
runRotateLockedSnapshotsDown();

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
displayArray();

# rename the recent snapshot
runRenameRecentSnapshot();

#clears snapshot locations from multi-linked array so new can be added
runClearSnapshotLocations();

#gets snapshots again after creating new storage snapshots and rotating existing snapshots
runGetSnapshotsByVolume();
displayArray();
}

# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
