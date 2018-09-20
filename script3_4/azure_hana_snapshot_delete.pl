#!/usr/bin/perl -w
#
# Copyright (C) 2017 Microsoft, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: azure_hana_snapshot_delete.pl
# Date 05/28/2018
my $version = "3.4";    #current version number of script

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Term::ANSIColor;

#Usage:  This script is used to allow Azure HANA customers to delete snapshots themselves without using the auto-delete functionality
# of the azure_hana_backup.pl script by decreasing the retention number. A customer can either delete an individual snapshot by entering the
# volume and snapshot details of the snapshot they wish to delete or they can remove all snapshots (data and shared volumes) associated with
# a hana backup ID.
#

#number of allowable SIDs. Number entered is one less than actual.. i.e if allowing 4 SIDs, then 3 is entered
my $numSID       = 9;
my $detailsStart = 11;

# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE = 0;
my $ERR_WARN = 1;

# Log levels -- LOG_INFO, LOG_CRIT, LOG_WARN, LOG_INPUT.  Bitmap values
my $LOG_INFO  = 1;    #standard output to file or displayed during verbose
my $LOG_CRIT  = 2;    #displays only critical output to console and log file
my $LOG_WARN  = 3;    #displays any warnings to console and log file
my $LOG_INPUT = 4;    #displays output to both console and file always, does not include new line command at end of output.

# Global parameters
my $exitWarn = 0;
my $exitCode;

#
# Global Tunables

#Usage:  the script allows the customer to delete backups by

# Global Tunables
#
#DO NOT MODIFY THESE VARIABLES!!!!
my $verbose = 0;
my @arrOutputLines;        #Keeps track of all messages (Info, Critical, and Warnings) for output to log file
my @fileLines;             #Input stream from HANABackupCustomerDetails.txt
my @strSnapSplit;
my @arrCustomerDetails;    #array that keeps track of all inputs on the HANABackupCustomerDetails.txt

my @HANASnapshotLocations; #contains list of volumes and snapshots that match backup id
my @snapshotLocations;     #arroy of all snapshots for certain volumes that match customer SID.
my @volLocations;          #array of all volumes that match SID input by customer
my $strBackupid;           #backupid if customer selects deletion by HANA backup id
my $strSnapshotName;       #snapshot name if customer selects deletion by voluem and snapshot
my $strVolumeLoc;          #volume location if customer selects deletion by voluem and snapshot
my $boolBackupidFound;     #proceeds with backupid deletion if backupid is found on a snapshot detail list
my $filename          = "HANABackupCustomerDetails.txt";
my $strHANAEnteredSID = $ARGV[0];                          #customer entered SID by argument to
my $strPrimaryHANAServerName;                              #Customer provided IP Address or Qualified Name of Primay HANA Server.
my $strPrimaryHANAServerIPAddress;                         #Customer provided IP address of Primary HANA Server
my $strUser;                                               #Microsoft Operations provided storage user name for backup access
my $strSVM;                                                #IP address of storage client for backup
my $sshCmd         = '/usr/bin/ssh';                       #typical location of ssh on SID
my $outputFilename = "";                                   #Generated filename for scipt output
my $HSR            = 0;                                    #used within only scripts, otherwise flagged to zero. **not used in this script**

#
# Name: runOpenParametersFiles
# Func: open the customer-based text file to gather required details
#

sub runOpenParametersFiles {
    open( my $fh, '<:encoding(UTF-8)', $filename )
        or die "Could not open file '$filename' $!";

    chomp( @fileLines = <$fh> );
    close $fh;
}

#
# Name: runVerifyParametersFile
# Func: verifies HANABackupCustomerDetails.txt input file adheres to expected format
#

sub runVerifyParametersFile {

    my $k = $detailsStart;
    my $lineNum;
    $lineNum = $k - 3;
    my $strServerName = "HANA Server Name:";
    if ( $fileLines[ $lineNum - 1 ] ) {
        if ( index( $fileLines[ $lineNum - 1 ], $strServerName ) eq -1 ) {
            logMsg( $LOG_WARN, "Expected " . $strServerName );
            logMsg( $LOG_WARN, "Verify line " . $lineNum . " is for the HANA Server Name. Exiting" );
            runExit($exitWarn);
        }
    }

    $lineNum = $k - 2;
    my $strHANAIPAddress = "HANA Server IP Address:";
    if ( $fileLines[ $lineNum - 1 ] ) {
        if ( index( $fileLines[ $lineNum - 1 ], $strHANAIPAddress ) eq -1 ) {
            logMsg( $LOG_WARN, "Expected " . $strHANAIPAddress );
            logMsg( $LOG_WARN, "Verify line " . $lineNum . " is the HANA Server IP Address. Exiting" );
            runExit($exitWarn);
        }
    }

    for my $i ( 0 ... $numSID ) {

        my $j = $i * 9;
        $lineNum = $k + $j;
        my $string1 = "######***SID #" . ( $i + 1 ) . " Information***#####";
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string1 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string1 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " is correct. Exiting" );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        my $string2 = "SID" . ( $i + 1 );
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string2 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string2 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " is for SID #$i. Exiting" );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        my $string3 = "###Provided by Microsoft Operations###";
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string3 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string3 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " is correct. Exiting" );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        my $string4 = "SID" . ( $i + 1 ) . " Storage Backup Name:";
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string4 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string4 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " contains the storage backup as provied by Microsoft Operations. Exiting." );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        my $string5 = "SID" . ( $i + 1 ) . " Storage IP Address:";
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string5 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string5 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " contains the Storage IP Address. Exiting." );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        my $string6 = "######     Customer Provided    ######";
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string6 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string6 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " is correct. Exiting." );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        my $string7 = "SID" . ( $i + 1 ) . " HANA instance number:";
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string7 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string7 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " contains the HANA instance number. Exiting." );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        my $string8 = "SID" . ( $i + 1 ) . " HANA HDBuserstore Name:";
        if ( $fileLines[ $lineNum - 1 ] ) {
            if ( index( $fileLines[ $lineNum - 1 ], $string8 ) eq -1 ) {
                logMsg( $LOG_WARN, "Expected " . $string8 );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " contains the HDBuserstore Name. Exiting." );
                runExit($exitWarn);
            }
        }
        $j++;
        $lineNum = $k + $j;
        if ( $#fileLines >= $lineNum - 1 and $fileLines[ $lineNum - 1 ] ) {
            if ( $fileLines[ $lineNum - 1 ] ne "" ) {
                logMsg( $LOG_WARN, "Expected Blank Line" );
                logMsg( $LOG_WARN, "Verify line " . $lineNum . " is blank. Exiting." );
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
    $lineNum = $k - 3;
    if ( substr( $fileLines[ $lineNum - 1 ], 0, 1 ) ne "#" ) {
        @strSnapSplit = split( /:/, $fileLines[ $lineNum - 1 ] );
    }
    else {
        logMsg( $LOG_WARN, "Cannot skip HANA Server Name. It is a required field" );
        runExit($exitWarn);
    }
    if ( $strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/ ) {
        $strSnapSplit[1] =~ s/^\s+|\s+$//g;
        $strPrimaryHANAServerName = $strSnapSplit[1];
        logMsg( $LOG_CRIT, "HANA Server Name: " . $strPrimaryHANAServerName );
    }

    undef @strSnapSplit;

    #HANA SERVER IP Address
    $lineNum = $k - 2;
    if ( substr( $fileLines[ $lineNum - 1 ], 0, 1 ) ne "#" ) {
        @strSnapSplit = split( /:/, $fileLines[ $lineNum - 1 ] );
    }
    else {
        logMsg( $LOG_WARN, "Cannot skip HANA Server IP Address. It is a required field" );
        runExit($exitWarn);
    }
    if ( $strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/ ) {
        $strSnapSplit[1] =~ s/^\s+|\s+$//g;
        $strPrimaryHANAServerIPAddress = $strSnapSplit[1];
        logMsg( $LOG_CRIT, "HANA Server IP Address: " . $strPrimaryHANAServerIPAddress );
    }

    #run through each SID up to number allowed in $numSID
    for my $i ( 0 .. $numSID ) {

        my $j = ( $detailsStart + $i * 9 );
        undef @strSnapSplit;

        if ( !$fileLines[$j] ) {
            next;
        }

        #SID
        if ( substr( $fileLines[$j], 0, 1 ) ne "#" ) {
            @strSnapSplit = split( /:/, $fileLines[$j] );
        }
        else {
            $arrCustomerDetails[$i][0] = "Skipped";
            logMsg( $LOG_CRIT, "SID" . ( $i + 1 ) . ": " . $arrCustomerDetails[$i][0] );
        }
        if ( $strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/ ) {
            $strSnapSplit[1] =~ s/^\s+|\s+$//g;
            $arrCustomerDetails[$i][0] = lc $strSnapSplit[1];
            logMsg( $LOG_CRIT, "SID" . ( $i + 1 ) . ": " . $arrCustomerDetails[$i][0] );
        }
        elsif ( !$strSnapSplit[1] and !$arrCustomerDetails[$i][0] ) {
            $arrCustomerDetails[$i][0] = "Omitted";
            logMsg( $LOG_CRIT, "SID" . ( $i + 1 ) . ": " . $arrCustomerDetails[$i][0] );

        }

        #Storage Backup Name
        if ( substr( $fileLines[ $j + 2 ], 0, 1 ) ne "#" ) {
            @strSnapSplit = split( /:/, $fileLines[ $j + 2 ] );
        }
        else {
            $arrCustomerDetails[$i][1] = "Skipped";
            logMsg( $LOG_CRIT, "Storage Backup Name: " . $arrCustomerDetails[$i][1] );
        }
        if ( $strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/ ) {
            $strSnapSplit[1] =~ s/^\s+|\s+$//g;
            $arrCustomerDetails[$i][1] = lc $strSnapSplit[1];
            logMsg( $LOG_CRIT, "Storage Backup Name: " . $arrCustomerDetails[$i][1] );
        }
        elsif ( !$strSnapSplit[1] and !$arrCustomerDetails[$i][1] ) {
            $arrCustomerDetails[$i][1] = "Omitted";
            logMsg( $LOG_CRIT, "Storage Backup Name: " . $arrCustomerDetails[$i][1] );

        }

        #Storage IP Address
        if ( substr( $fileLines[ $j + 3 ], 0, 1 ) ne "#" ) {
            @strSnapSplit = split( /:/, $fileLines[ $j + 3 ] );
        }
        else {
            $arrCustomerDetails[$i][2] = "Skipped";
            logMsg( $LOG_CRIT, "Storage Backup Name: " . $arrCustomerDetails[$i][2] );
        }
        if ( $strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/ ) {
            $strSnapSplit[1] =~ s/^\s+|\s+$//g;
            $arrCustomerDetails[$i][2] = $strSnapSplit[1];
            logMsg( $LOG_CRIT, "Storage IP Address: " . $arrCustomerDetails[$i][2] );
        }
        elsif ( !$strSnapSplit[1] and !$arrCustomerDetails[$i][2] ) {
            $arrCustomerDetails[$i][2] = "Omitted";
            logMsg( $LOG_CRIT, "Storage Backup Name: " . $arrCustomerDetails[$i][2] );

        }

        #HANA Instance Number
        if ( substr( $fileLines[ $j + 5 ], 0, 1 ) ne "#" ) {
            @strSnapSplit = split( /:/, $fileLines[ $j + 5 ] );
        }
        else {
            $arrCustomerDetails[$i][3] = "Skipped";
            logMsg( $LOG_CRIT, "HANA Instance Number: " . $arrCustomerDetails[$i][3] );
        }
        if ( $strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/ ) {
            $strSnapSplit[1] =~ s/^\s+|\s+$//g;
            $arrCustomerDetails[$i][3] = $strSnapSplit[1];
            logMsg( $LOG_CRIT, "HANA Instance Number: " . $arrCustomerDetails[$i][3] );
        }
        elsif ( !$strSnapSplit[1] and !$arrCustomerDetails[$i][3] ) {
            $arrCustomerDetails[$i][3] = "Omitted";
            logMsg( $LOG_CRIT, "HANA Instance Number: " . $arrCustomerDetails[$i][3] );

        }

        #HANA User name
        if ( substr( $fileLines[ $j + 6 ], 0, 1 ) ne "#" ) {
            @strSnapSplit = split( /:/, $fileLines[ $j + 6 ] );
        }
        else {
            $arrCustomerDetails[$i][4] = "Skipped";
            logMsg( $LOG_CRIT, "HANA Instance Number: " . $arrCustomerDetails[$i][4] );
        }
        if ( $strSnapSplit[1] and $strSnapSplit[1] !~ /^\s*$/ ) {
            $strSnapSplit[1] =~ s/^\s+|\s+$//g;
            $arrCustomerDetails[$i][4] = uc $strSnapSplit[1];
            logMsg( $LOG_CRIT, "HANA Userstore Name: " . $arrCustomerDetails[$i][4] );
        }
        elsif ( !$strSnapSplit[1] and !$arrCustomerDetails[$i][4] ) {
            $arrCustomerDetails[$i][4] = "Omitted";
            logMsg( $LOG_CRIT, "HANA Instance Number: " . $arrCustomerDetails[$i][4] );

        }
    }
}

#
# Name: runVerifySIDDetails
# Func: ensures that all necessary details for an SID entered are provided and understood.
#

sub runVerifySIDDetails {

    NUMSID: for my $i ( 0 ... $numSID ) {
        my $checkSID                = 1;
        my $checkBackupName         = 1;
        my $checkIPAddress          = 1;
        my $checkHANAInstanceNumber = 1;
        my $checkHANAUserstoreName  = 1;

        for my $j ( 0 ... 4 ) {
            if ( !$arrCustomerDetails[$i][$j] ) { last NUMSID; }
        }

        if ( $arrCustomerDetails[$i][0] eq "Omitted" ) {
            $checkSID = 0;
        }
        if ( $arrCustomerDetails[$i][1] eq "Omitted" ) {
            $checkBackupName = 0;
        }
        if ( $arrCustomerDetails[$i][2] eq "Omitted" ) {
            $checkIPAddress = 0;
        }
        if ( $arrCustomerDetails[$i][3] eq "Omitted" ) {
            $checkHANAInstanceNumber = 0;
        }
        if ( $arrCustomerDetails[$i][4] eq "Omitted" ) {
            $checkHANAUserstoreName = 0;
        }

        if (    $checkSID eq 0
            and $checkBackupName eq 0
            and $checkIPAddress eq 0
            and $checkHANAInstanceNumber eq 0
            and $checkHANAUserstoreName eq 0 ) {
            next;
        }
        elsif ( $checkSID eq 1
            and $checkBackupName eq 1
            and $checkIPAddress eq 1
            and $checkHANAInstanceNumber eq 1
            and $checkHANAUserstoreName eq 1 ) {
            next;
        }
        else {
            if ( $checkSID eq 0 ) {
                logMsg( $LOG_WARN, "Missing SID" . ( $i + 1 ) . " Exiting." );
            }
            if ( $checkBackupName eq 0 ) {
                logMsg( $LOG_WARN, "Missing Storage Backup Name for SID" . ( $i + 1 ) . " Exiting." );
            }
            if ( $checkIPAddress eq 0 ) {
                logMsg( $LOG_WARN, "Missing Storage IP Address for SID" . ( $i + 1 ) . " Exiting." );
            }
            if ( $checkHANAInstanceNumber eq 0 ) {
                logMsg( $LOG_WARN, "Missing HANA Instance User Name for SID" . ( $i + 1 ) . " Exiting." );
            }
            if ( $checkHANAUserstoreName eq 0 ) {
                logMsg( $LOG_WARN, "Missing HANA Userstore Name for SID" . ( $i + 1 ) . " Exiting." );
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

sub logMsg {

    # grab the error string
    my ( $errValue, $msgString ) = @_;
    my $timestamp = localtime->strftime("[%d/%b/%Y:%H:%M:%S %z]");    # refer to Common Log Format

    my $str;

    #$LOG_INFO
    if ( $errValue eq 1 ) {
        $str .= "$timestamp $msgString";
        $str .= "\n";
        if ( $verbose eq 1 ) {
            print $str;
        }
        push( @arrOutputLines, $str );
    }

    #$LOG_CRIT
    if ( $errValue eq 2 ) {
        $str .= "$timestamp $msgString";
        $str .= "\n";
        print $str;
        push( @arrOutputLines, $str );
    }

    #$LOG_WARN
    if ( $errValue eq 3 ) {
        $str .= "$timestamp WARNING: $msgString\n";
        $exitWarn = 1;
        print color('bold red');
        print "$str\n";
        print color('reset');
        push( @arrOutputLines, $str );
    }

    #$LOG_ENTRY
    if ( $errValue eq 4 ) {
        $str .= "$timestamp $msgString\n";
        print "$str\n";
        push( @arrOutputLines, $str );
    }
}

#
# Name: runExit()
# Func: Exit the script, but be sure to print a report if one is
#       requested.
#
sub runExit {
    $exitCode = shift;
    if ( ( $exitWarn != 0 ) && ( !$exitCode ) ) {
        $exitCode = $ERR_WARN;
    }

    # print the error code message (if verbose is selected)
    if ( $verbose != 0 ) {
        logMsg( $LOG_CRIT, "Exiting with return code: $exitCode" );
        if ( $exitCode eq 0 ) {

            print color ('bold green');
            logMsg( $LOG_CRIT, "Command completed successfully." );
            print color ('reset');
        }
        if ( $exitCode eq 1 ) {

            print color ('bold red');
            logMsg( $LOG_CRIT, "Command failed. Please check screen output or created logs for errors." );
            print color ('reset');
        }

    }
    runPrintFile();

    # exit with our error code
    exit($exitCode);
}

#
# Name: runShellCmd
# Func: Run a command in the shell and return the results.
#
sub runShellCmd {
    my ($strShellCmd) = @_;
    return (`$strShellCmd 2>&1`);
}

#
# Name: runSSHCmd
# Func: Run an SSH command.
#
sub runSSHCmd {
    my ($strShellCmd) = @_;
    return (`"$sshCmd" -l $strUser $strSVM 'set -showseparator ","; $strShellCmd' 2>&1`);
}

#
# Name: runDeleteSnapshot()
# Func: Get the set of production volumes that match specified HANA instance.
#
sub runDeleteSnapshot {
    my $strVolumeInput = "Please enter the volume location of the snapshot you wish to delete: ";
    my $inputVolumeLoc;
    do {
        print color('bold cyan');
        logMsg( $LOG_INPUT, $strVolumeInput );
        print color('reset');
        $inputVolumeLoc = <STDIN>;
        $inputVolumeLoc =~ s/[\n\r\f\t]//g;
        chomp $inputVolumeLoc;
        $strVolumeLoc = $inputVolumeLoc;
        logMsg( $LOG_CRIT, "Volume Location: " . $inputVolumeLoc );
    } while ( $inputVolumeLoc !~ m/vol/i );

    my $inputSnapshotName;
    my $strSnapshotInput = "Please enter the snapshot you wish to delete:   ";
    do {
        print color('bold cyan');
        logMsg( $LOG_INPUT, $strSnapshotInput );
        print color('reset');
        $inputSnapshotName = <STDIN>;
        $inputSnapshotName =~ s/[\n\r\f\t]//g;
        $strSnapshotName = $inputSnapshotName;
        chomp $strSnapshotName;
    } while ( $inputSnapshotName !~ m/./i or $inputSnapshotName !~ m/-/i );

    my $inputProceedSnapshot;
    my $strProceedSnapshot = "You have requested to delete snapshot $strSnapshotName from volume $strVolumeLoc. Any data that exists only on this snapshot is lost forever. Do you wish to proceed (yes/no)?   ";
    logMsg( $LOG_CRIT, $strProceedSnapshot );

    do {
        print color('bold cyan');
        logMsg( $LOG_INPUT, "Please enter (yes/no):  " );
        print color('reset');
        $inputProceedSnapshot = <STDIN>;
        $inputProceedSnapshot =~ s/[\n\r\f\t]//g;
        if ( $inputProceedSnapshot =~ m/no/i ) {
            runExit($ERR_WARN);
        }
    } while ( $inputProceedSnapshot !~ m/yes/i );

    logMsg( $LOG_CRIT, "*********************Deleting Snapshot $strSnapshotName from Volume $strVolumeLoc**********************" );

    my $strSSHCmd = "volume snapshot show -volume $strVolumeLoc -snapshot $strSnapshotName -fields create-time";
    my @out       = runSSHCmd($strSSHCmd);
    if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Please verify correct volume: $strVolumeLoc and snapshot: $strSnapshotName were provided" );
        logMsg( $LOG_WARN, "Otherwise, please wait a few minutes and try again" );
        logMsg( $LOG_WARN, "If issue persists, please contact Microsoft Operations for assistance" );
    }
    my @strSubArr = split( /,/, $out[3] );
    my $strSnapshotTime = $strSubArr[3];

    my $checkSnapshotAge = runCheckSnapshotAge($strSnapshotTime);
    if ($checkSnapshotAge) {
        my $strSSHCmd = "volume snapshot delete -volume $strVolumeLoc -snapshot $strSnapshotName";
        my @out       = runSSHCmd($strSSHCmd);
        if ( $? ne 0 ) {
            logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
            logMsg( $LOG_WARN, "Please try again in a few minutes" );
            logMsg( $LOG_WARN, "If issue persists, Please contact Microsoft Operations for assistance" );
        }
        else {
            print color('bold green');
            logMsg( $LOG_CRIT, "Snapshot $strSnapshotName of volume $strVolumeLoc was successfully deleted" );
            print color('reset');
        }

    }
    else {

        logMsg( $LOG_WARN, "$strSnapshotName is aged less than 10 minutes... cannot delete due to potential replica interference. Stopping execution." );
        runExit($exitWarn);
    }
}

sub runDeleteHANASnapshot {
    my $strBackupidInput = "Please enter the backup id of the HANA Storage Snapshot you wish to delete: ";
    print color('bold cyan');
    logMsg( $LOG_INPUT, $strBackupidInput );
    print color('reset');
    push( @arrOutputLines, $strBackupidInput );
    my $inputBackupid = <STDIN>;
    $inputBackupid =~ s/[\n\r\f\t]//g;
    $strBackupid = $inputBackupid;

    my $inputProceedHANASnapshot;
    my $strProceedHANASnapshot = "You have requested to delete all snapshots associated with HANA Backup ID $strBackupid. Any data that exists solely on these snapshots are lost forever. Do you wish to proceed (yes/no)?   ";
    print color('bold cyan');
    logMsg( $LOG_INPUT, $strProceedHANASnapshot );
    print color('reset');
    do {
        print color('bold cyan');
        logMsg( $LOG_INPUT, "Please enter (yes/no):  " );
        print color('reset');
        $inputProceedHANASnapshot = <STDIN>;
        $inputProceedHANASnapshot =~ s/[\n\r\f\t]//g;
        if ( $inputProceedHANASnapshot =~ m/no/i ) {
            runExit($ERR_WARN);
        }
    } while ( $inputProceedHANASnapshot !~ m/yes/i );

    #get the list of volumes in the tenant
    runGetVolumeLocations();

    #get snapshots in the volume
    runGetSnapshotsByVolume();

    #get the hanabackupid, if exists, for all snapshots
    runGetSnapshotDetailsBySnapshot();

    runVerifyHANASnapshot();
    if ($boolBackupidFound) {
        for my $x ( 0 .. $#HANASnapshotLocations ) {
            my $strSSHCmd = "volume snapshot show -volume $HANASnapshotLocations[$x][0] -snapshot $HANASnapshotLocations[$x][1] -fields create-time";
            my @out       = runSSHCmd($strSSHCmd);
            if ( $? ne 0 ) {
                logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                logMsg( $LOG_WARN, "Please try again in a few minutes." );
                logMsg( $LOG_WARN, "If issue persists, Please contact Microsoft Operations for assistance" );
                runExit($exitWarn);
            }
            my @strSubArr = split( /,/, $out[3] );
            my $strSnapshotTime = $strSubArr[3];
            logMsg( $LOG_INFO, "Checking time stamp for snapshot $HANASnapshotLocations[$x][1] of volume $HANASnapshotLocations[$x][0]" );
            my $checkSnapshotAge = runCheckSnapshotAge($strSnapshotTime);
            if ($checkSnapshotAge) {
                my $strSSHCmd = "volume snapshot delete -volume $HANASnapshotLocations[$x][0] -snapshot $HANASnapshotLocations[$x][1]";
                my @out       = runSSHCmd($strSSHCmd);
                if ( $? ne 0 ) {
                    logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                    logMsg( $LOG_WARN, "Please wait a few minutes and try again" );
                    logMsg( $LOG_WARN, "If issues persists, Please contact Microsoft Operations for assistance." );
                }
                else {
                    print color('bold green');
                    logMsg( $LOG_CRIT, "Snapshot $HANASnapshotLocations[$x][1] of volume $HANASnapshotLocations[$x][0] was successfully deleted" );
                    print color('reset');
                }

            }
            else {
                logMsg( $LOG_WARN, "$HANASnapshotLocations[$x][1] is aged less than 10 minutes... cannot delete due to potential replica interference. Stopping execution." );
                runExit($ERR_WARN);
            }

        }
    }
    else {
        print color('bold red');
        logMsg( $LOG_WARN, "No snapshots found that correspond to HANA Backup id $strBackupid.  Please double-check the HANA Backup ID as specified in HANA Studio and try again.  If you feel you are reaching this message in error, please open a ticket with MS Operations for additional support." );
        runExit($ERR_WARN);
    }
}

sub runGetVolumeLocations {
    logMsg( $LOG_INFO, "**********************Getting list of volumes****************************" );
    my $strSSHCmd = "volume show -volume *" . $strHANAEnteredSID . "* -volume *data* | *shared* -volume !*dp* | !*xdp* -type RW -fields volume";
    logMsg( $LOG_INFO, "SSH Command:" . $strSSHCmd );
    my @out = runSSHCmd($strSSHCmd);
    if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Retrieving volumes failed.  Exiting script." );
        runExit($ERR_WARN);
    }
    else {
        logMsg( $LOG_INFO, "Volume show completed successfully." );
    }
    my $i       = 0;
    my $listnum = 0;
    my $count   = $#out - 1;
    for my $j ( 0 ... $count ) {
        $listnum++;
        next if ( $listnum <= 3 );
        chop $out[$j];
        my @arr = split( /,/, $out[$j] );

        my $name = $arr[ $#arr - 1 ];

        if ( defined $name ) {
            logMsg( $LOG_INFO, "Adding volume $name to the snapshot list." );
            push( @volLocations, $name );

        }
        $i++;
    }
}

sub runGetSnapshotsByVolume {
    logMsg( $LOG_INFO, "**********************Adding list of snapshots to volume list**********************" );
    my $i = 0;
    my $k = 0;
    logMsg( $LOG_INFO, "Collecting set of snapshots for each volume..." );
    foreach my $volName (@volLocations) {
        my $j = 0;
        $snapshotLocations[$i][0][0] = $volName;
        my $strSSHCmd = "volume snapshot show -volume $volName -fields snapshot";
        my @out       = runSSHCmd($strSSHCmd);
        if ( $? ne 0 ) {
            logMsg( $LOG_INFO, "Running '" . $strSSHCmd . "' failed: $?" );
            logMsg( $LOG_INFO, "Possible reason: No snapshots were found for volume: $volName." );
            next;
        }
        my $listnum = 0;
        $j = 1;
        my $count = $#out - 1;
        foreach my $k ( 0 ... $count ) {

            $listnum++;
            if ( $listnum <= 4 ) {
                chop $out[$k];
                $j = 1;
                next;
            }

            my @strSubArr = split( /,/, $out[$k] );
            my $strSub = $strSubArr[ $#strSubArr - 1 ];
            if ( index( $strSub, "snapmirror" ) == -1 ) {

                #print "$strSub\n";
                logMsg( $LOG_INFO, "Snapshot $strSub added to $snapshotLocations[$i][0][0]" );
                $snapshotLocations[$i][$j][0] = $strSub;
                $j++;
            }
        }
        $i++;
    }

}

sub runGetSnapshotDetailsBySnapshot {
    logMsg( $LOG_INFO, "**********************Adding snapshot details to snapshot list**********************" );

    logMsg( $LOG_INFO, "Collecting backupids for each snapshot." );
    for my $x ( 0 .. $#snapshotLocations ) {
        my $aref = $snapshotLocations[$x];
        for my $y ( 1 .. $#{$aref} ) {

            my $strSSHCmd = "volume snapshot show -volume $snapshotLocations[$x][0][0] -snapshot $snapshotLocations[$x][$y][0] -fields snapshot, comment";
            my @out       = runSSHCmd($strSSHCmd);

            if ( $? ne 0 ) {
                logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
                logMsg( $LOG_WARN, "Please try again in a few minutes." );
                logMsg( $LOG_WARN, "If issue persists, please contact Microsoft Operations for assistance." );
            }
            my @strSubArr = split( /,/, $out[3] );
            my $strSub = $strSubArr[ $#strSubArr - 1 ];
            $snapshotLocations[$x][$y][1] = $strSub;
        }

    }
}

sub runVerifyHANASnapshot {
    logMsg( $LOG_CRIT, "**********************Seeking backup id in found Storage Snapshots**********************" );
    my $k = 0;
    for my $i ( 0 .. $#snapshotLocations ) {
        my $aref = $snapshotLocations[$i];
        for my $j ( 0 .. $#{$aref} ) {
            if ( defined( $snapshotLocations[$i][$j][1] ) ) {
                if ( $snapshotLocations[$i][$j][1] eq $strBackupid ) {
                    $boolBackupidFound = 1;
                    $HANASnapshotLocations[$k][0] =
                        $snapshotLocations[$i][0][0];
                    $HANASnapshotLocations[$k][1] =
                        $snapshotLocations[$i][$j][0];
                    logMsg( $LOG_CRIT, "Adding Snapshot $HANASnapshotLocations[$k][1] from volume $HANASnapshotLocations[$k][0]" );
                    $k++;
                }
            }
        }
    }

}

sub runCheckSnapshotAge {

    my $snapshotTimeStamp = shift;
    $snapshotTimeStamp =~ tr/"//d;

    my $t = Time::Piece->strptime( $snapshotTimeStamp, "%a %b %d %H:%M:%S %Y" );    # UTC
    my $tNum = str2time($t);

    my $currentTime = gmtime->strftime("%a %b %e %H:%M:%S %Y");                        # UTC
    my $currentT    = Time::Piece->strptime( $currentTime, "%a %b %d %H:%M:%S %Y" );
    my $currentTNum = str2time($currentT);

    print( "Snapshot time stamp = " . $snapshotTimeStamp . " UTC\n" );
    print( "Current system time = " . $currentTime . " UTC\n" );

    if ( ( str2time($currentT) - str2time($t) ) > 600 ) {
        logMsg( $LOG_INFO, "Time threshold passed.  Okay to proceed in snapshot deletion" );
        return 1;
    }
    else {
        return 0;
    }
}

sub runPrintFile {
    my $myLine;
    my $date = localtime->strftime('%Y-%m-%d_%H%M');
    if ( defined($strHANAEnteredSID) ) {
        $outputFilename = "snapshotDelete.$strHANAEnteredSID.$date.txt";
    }
    else {
        $outputFilename = "snapshotDelete.$date.txt";
    }
    my $existingdir = './snapshotLogs';
    mkdir $existingdir
        unless -d $existingdir;    # Check if dir exists. If not create it.
    open my $fileHandle, ">>", "$existingdir/$outputFilename"
        or die "Can't open '$existingdir/$outputFilename'\n";
    print color('bold green');
    logMsg( $LOG_CRIT, "Log file created at " . $existingdir . "/" . $outputFilename );
    print color('reset');
    foreach $myLine (@arrOutputLines) {
        print $fileHandle $myLine;
    }
    close $fileHandle;
}

##### --------------------- MAIN CODE --------------------- #####
logMsg( $LOG_CRIT, "Executing Azure HANA Snapshot Delete Script, Version $version" );
my $SCRIPT_NAME = $0;
my $SCRIPT_HASH = `/usr/bin/md5sum $SCRIPT_NAME`;
logMsg( $LOG_INFO, "Verify script -> " . $SCRIPT_HASH );

if ( defined $ARGV[1] ) {
    if ( $ARGV[1] eq "verbose" ) {

        $verbose = 1;
    }
    else {
        $verbose = 0;
    }
}

if ( !defined $ARGV[0] ) {

    logMsg( $LOG_WARN, "Please enter HANA Instance pertaining to the snapshot you wish to delete." );
    runExit($ERR_WARN);
}

#read and store each line of HANABackupCustomerDetails to fileHandle
runOpenParametersFiles();

#verify each line is expected based on template, otherwise throw error.
runVerifyParametersFile();

#add Parameters to usable array customerDetails
runGetParameterDetails();

#verify all required details entered for each SID
runVerifySIDDetails();
print color('bold green');
logMsg( $LOG_CRIT, "----------------------Executing Main Code------------------------------------" );
print color('reset');

my $i = 0;

while ( $arrCustomerDetails[$i][0] ne $strHANAEnteredSID ) {

    if ( $i eq $numSID ) {

        logMsg( $LOG_WARN, "The Entered SID was not found within the HANABackupCustomerDetails.txt file.  Please double-check that file." );
        print color('bold red');
        runExit($ERR_WARN);

    }
    $i++;

}

$strUser = $arrCustomerDetails[$i][1];
$strSVM  = $arrCustomerDetails[$i][2];

my $strSnapshotDeleteMessage = "This script is intended to delete either a single snapshot or all snapshots that pertain to a particular HANA storage snapshot by its HANA Backup ID
found in HANA Studio.  A snapshot cannot be deleted if it is less than an 10 minutes old as deletion can interfere with replication. Please enter whether you wish to delete by backupid
or snapshot, and, if by snapshot, enter the volume name and snapshot name where the snapshot is found.  The azure_hana_snapshot_details script may be used to identify individual
snapshot names and volume locations.";

logMsg( $LOG_INPUT, $strSnapshotDeleteMessage );
print "\n";

my $strTypeInput = "Do you want to delete by snapshot name or by HANA backup id?";
print color('bold cyan');
logMsg( $LOG_CRIT, $strTypeInput );
print color('reset');

my $inputDeleteType;
do {
    print color('bold cyan');
    logMsg( $LOG_INPUT, "Please enter (backupid/snapshot/quit): " );
    print color('reset');
    $inputDeleteType = <STDIN>;
    $inputDeleteType =~ s/[\n\r\f\t]//g;
    logMsg( $LOG_INFO, "Command Entered: $inputDeleteType" );
    if ( $inputDeleteType =~ m/backupid/i ) {

        #print "matched backupid\n";
        runDeleteHANASnapshot();

        # if we get this far, we can exit cleanly
        print color('bold green');
        logMsg( $LOG_CRIT, "Command completed successfully." );
        print color('reset');

        # time to exit
        runExit($ERR_NONE);
    }
    if ( $inputDeleteType =~ m/snapshot/i ) {

        #print "matched snapshot\n";
        runDeleteSnapshot();
        #
        print color('bold green');
        logMsg( $LOG_CRIT, "Command completed successfully." );
        print color('reset');

        # time to exit
        runExit($ERR_NONE);
    }
} while ( $inputDeleteType !~ m/quit/i );

# time to exit
runExit($ERR_NONE);
