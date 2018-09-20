#!/usr/bin/perl -w
#
# Copyright (C) 2017 Microsoft, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: azure_hana_replication_status.pl
# Date 05/15/2018
my $version = "3.4";    #current version number of script

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Term::ANSIColor;

#Usage:  This script is used to show the status of the storage replication for DR purposes.
#
my $numSID       = 9;
my $detailsStart = 11;

# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE = 0;
my $ERR_WARN = 1;

# Log levels -- LOG_INFO, LOG_CRIT, LOG_WARN.  Bitmap values
my $LOG_INFO  = 1;    #standard output to file or displayed during verbose
my $LOG_CRIT  = 2;    #displays only critical output to console and log file
my $LOG_WARN  = 3;    #displays any warnings to console and log file
my $LOG_ENTRY = 4;    #does not create newline at end of message. Useful for changing color in middle of line.

# Global parameters
my $exitWarn = 0;
my $exitCode;

#
# Global Tunables
#

my @arrOutputLines;                   #Keeps track of all messages (Info, Critical, and Warnings) for output to log file
my @fileLines;                        #Input stream from HANABackupCustomerDetails.txt
my @strSnapSplit;
my @arrCustomerDetails;               #array that keeps track of all inputs on the HANABackupCustomerDetails.txt
my $strPrimaryHANAServerName;         #Customer provided IP Address or Qualified Name of Primay HANA Server.
my $strPrimaryHANAServerIPAddress;    #Customer provided IP address of Primary HANA Server
my $filename = "HANABackupCustomerDetails.txt";
my $strUser;                          #Microsoft Operations provided storage user name for backup access
my $strSVM;                           #IP address of storage client for backup
my $sshCmd = '/usr/bin/ssh';          #typical location of ssh on SID
my $strHANASID;                       #The customer entered HANA SID for each iteration of SID entered with HANABackupCustomerDetails.txt

my $outputFilename = "";              #Generated filename for scipt output
my @snapMirrorLocations;              #array that contains the list of relationships and relationship details
my $verbose = 1;
my $HSR     = 0;                      #used within only scripts, otherwise flagged to zero. **not used in this script**

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

        if ( $checkSID eq 0 and $checkBackupName eq 0 and $checkIPAddress eq 0 and $checkHANAInstanceNumber eq 0 and $checkHANAUserstoreName eq 0 ) {
            next;
        }
        elsif ( $checkSID eq 1 and $checkBackupName eq 1 and $checkIPAddress eq 1 and $checkHANAInstanceNumber eq 1 and $checkHANAUserstoreName eq 1 ) {
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
        logMsg( $LOG_INFO, "Exiting with return code: $exitCode" );
        if ( $exitCode eq 0 ) {

            print color ('bold green');
            logMsg( $LOG_INFO, "Command completed successfully." );
            print color ('reset');
        }
        if ( $exitCode eq 1 ) {

            print color ('bold red');
            logMsg( $LOG_INFO, "Command failed. Please check screen output or created logs for errors." );
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

    #logMsg($LOG_INFO,"inside runShellCmd");
    my ($strShellCmd) = @_;
    return (`$strShellCmd 2>&1`);
}

#
# Name: runSSHCmd
# Func: Run an SSH command.
#
sub runSSHCmd {

    #logMsg($LOG_INFO,"inside runSSHCmd");
    my ($strShellCmd) = @_;
    return (`"$sshCmd" -l $strUser $strSVM 'set -showseparator ","; $strShellCmd' 2>&1`);
}

sub runGetSnapmirrorRelationships {
    print color('bold green');
    logMsg( $LOG_INFO, "**********************Getting list of replication relationships that match HANA instance provided**********************" );
    logMsg( $LOG_INFO, "Collecting set of relationships hosting HANA matching pattern *$strHANASID* ..." );
    print color('reset');

    #  my $strSSHCmd = "snapmirror show -destination-volume *dp* -destination-volume *".$strHANASID."* -fields destination-volume, status, state, lag-time, last-transfer-size";
    my $strSSHCmd = "snapmirror show -type dp|xdp -destination-volume *" . $strHANASID . "* -fields destination-volume, status, state, lag-time, last-transfer-size,newest-snapshot";
    my @out       = runSSHCmd($strSSHCmd);
    if ( $? ne 0 ) {
        logMsg( $LOG_WARN, "Running '" . $strSSHCmd . "' failed: $?" );
        logMsg( $LOG_WARN, "Retrieving replication relationships failed for $strHANASID." );
        logMsg( $LOG_WARN, "Please check to make sure that $strHANASID is the correct HANA instance." );
        logMsg( $LOG_WARN, "Additionally, please verify this script is executed in the Disaster Recovery location and Disaster Recovery has been implemented by Microsoft Operations." );
        logMsg( $LOG_WARN, "Otherwise, please wait a few minutes and try again." );
        logMsg( $LOG_WARN, "If issue persists, Please contact Microsoft Operations for assistance." );
    }
    else {
        print color('bold green');
        logMsg( $LOG_INFO, "Relationship show completed successfully." );
        print color('reset');
    }
    my $j       = 0;
    my $listnum = 0;
    my $count   = $#out - 1;
    for my $i ( 0 ... $count ) {

        $listnum++;
        next if ( $listnum <= 3 );
        chop $out[$i];

        my @arr = split( /,/, $out[$i] );
        $snapMirrorLocations[$j][0] = $arr[2];
        $snapMirrorLocations[$j][1] = $arr[3];
        $snapMirrorLocations[$j][2] = $arr[4];
        $snapMirrorLocations[$j][3] = $arr[5];
        $snapMirrorLocations[$j][4] = $arr[6];
        $snapMirrorLocations[$j][5] = $arr[7];
        $snapMirrorLocations[$j][6] = $arr[8];
        $j++;
    }

}

sub displayArray {
    print color('bold blue');
    logMsg( $LOG_INFO, "**********************Displaying Relationships by Volume**********************" );
    print color('reset');
    for my $i ( 0 .. $#snapMirrorLocations ) {

        if ( $snapMirrorLocations[$i][0] =~ /data/ ) {

            print color('bold green');
            logMsg( $LOG_INFO, $snapMirrorLocations[$i][0] );
            print color('reset');
            print color('bold cyan');
            logMsg( $LOG_INFO, "-------------------------------------------------" );
            print color('reset');
            if ( $snapMirrorLocations[$i][1] =~ /Broken-off/ ) {
                logMsg( $LOG_ENTRY, "Link Status: " );
                print color('bold red');
                logMsg( $LOG_INFO, "Broken-Off" );
                logMsg( $LOG_INFO, "Please contact Microsoft Operations immediately." );
                print color('reset');
            }
            else {
                logMsg( $LOG_ENTRY, "Link Status: " );
                print color('bold green');
                logMsg( $LOG_INFO, "Active" );
                print color('reset');
            }
            logMsg( $LOG_INFO, "Current Replication Activity: " . $snapMirrorLocations[$i][2] );
            logMsg( $LOG_INFO, "Latest Snapshot Replicated: " . $snapMirrorLocations[$i][3] );
            logMsg( $LOG_INFO, "Size of Latest Snapshot Replicated: " . $snapMirrorLocations[$i][4] );
            logMsg( $LOG_INFO, "Current Lag Time between snapshots: " . $snapMirrorLocations[$i][5] );
            logMsg( $LOG_INFO, "   ***Less than 30 minutes is recommended***" );
            logMsg( $LOG_INFO, "*************************************************" );

        }
        if ( $snapMirrorLocations[$i][0] =~ /log/ ) {

            print color('bold green');
            logMsg( $LOG_INFO, $snapMirrorLocations[$i][0] );
            print color('reset');
            print color('bold cyan');
            logMsg( $LOG_INFO, "-------------------------------------------------" );
            print color('reset');
            if ( $snapMirrorLocations[$i][1] =~ /Broken-off/ ) {
                logMsg( $LOG_ENTRY, "Link Status: " );
                print color('bold red');
                logMsg( $LOG_INFO, "Broken-Off" );
                logMsg( $LOG_INFO, "Please contact Microsoft Operations immediately." );
                print color('reset');
            }
            else {
                logMsg( $LOG_ENTRY, "Link Status: " );
                print color('bold green');
                logMsg( $LOG_INFO, "Active" );
                print color('reset');
            }
            logMsg( $LOG_INFO, "Current Replication Activity: " . $snapMirrorLocations[$i][2] );
            logMsg( $LOG_INFO, "Latest Snapshot Replicated: " . $snapMirrorLocations[$i][3] );
            logMsg( $LOG_INFO, "Size of Latest Snapshot Replicated: " . $snapMirrorLocations[$i][4] );
            logMsg( $LOG_INFO, "Current Lag Time between snapshots: " . $snapMirrorLocations[$i][5] );
            logMsg( $LOG_INFO, "   ***Less than 10 minutes is recommended***" );
            logMsg( $LOG_INFO, "*************************************************" );

        }
        if ( $snapMirrorLocations[$i][0] =~ /shared/ ) {

            print color('bold green');
            logMsg( $LOG_INFO, $snapMirrorLocations[$i][0] );
            print color('reset');
            print color('bold cyan');
            logMsg( $LOG_INFO, "-------------------------------------------------" );
            print color('reset');
            if ( $snapMirrorLocations[$i][1] =~ /Broken-off/ ) {
                logMsg( $LOG_ENTRY, "Link Status: " );
                print color('bold red');
                logMsg( $LOG_INFO, "Broken-Off" );
                logMsg( $LOG_INFO, "Please contact Microsoft Operations immediately." );
                print color('reset');
            }
            else {
                logMsg( $LOG_ENTRY, "Link Status: " );
                print color('bold green');
                logMsg( $LOG_INFO, "Active" );
                print color('reset');
            }
            logMsg( $LOG_INFO, "Current Replication Activity: " . $snapMirrorLocations[$i][2] );
            logMsg( $LOG_INFO, "Latest Snapshot Replicated: " . $snapMirrorLocations[$i][3] );
            logMsg( $LOG_INFO, "Size of Latest Snapshot Replicated: " . $snapMirrorLocations[$i][4] );
            logMsg( $LOG_INFO, "Current Lag Time between snapshots: " . $snapMirrorLocations[$i][5] );
            logMsg( $LOG_INFO, "   ***Less than 30 minutes is recommended***" );
            logMsg( $LOG_INFO, "*************************************************" );
        }
    }
}

sub runClearSnapMirrorRelationships {

    undef @snapMirrorLocations;

}

sub runPrintFile {
    my $myLine;
    my $date = localtime->strftime('%Y-%m-%d_%H%M');
    $outputFilename = "replicationStatus.$date.txt";
    my $existingdir = './snapshotLogs';
    mkdir $existingdir unless -d $existingdir;    # Check if dir exists. If not create it.
    open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
    print color('bold green');
    logMsg( $LOG_CRIT, "Log file created at " . $existingdir . "/" . $outputFilename );
    print color('reset');

    foreach $myLine (@arrOutputLines) {
        print $fileHandle $myLine;

    }
    close $fileHandle;
}

##### --------------------- MAIN CODE --------------------- #####
logMsg( $LOG_INFO, "Executing Azure HANA Replication Status Script, Version $version" );
my $SCRIPT_NAME = $0;
my $SCRIPT_HASH = `/usr/bin/md5sum $SCRIPT_NAME`;
logMsg( $LOG_INFO, "Verify script -> " . $SCRIPT_HASH );

#read and store each line of HANABackupCustomerDetails to fileHandle
runOpenParametersFiles();

#verify each line is expected based on template, otherwise throw error.
runVerifyParametersFile();

#add Parameters to usable array customerDetails
runGetParameterDetails();

#verify all required details entered for each SID
runVerifySIDDetails();

for my $i ( 0 .. $numSID ) {

    #logMsg($LOG_INFO,"arrCustomerDetails[".$i."][0]: ". $arrCustomerDetails[$i][0]);
    if ( $arrCustomerDetails[$i][0] and ( $arrCustomerDetails[$i][0] ne "Skipped" and $arrCustomerDetails[$i][0] ne "Omitted" ) ) {
        $strHANASID = lc $arrCustomerDetails[$i][0];
        print color('bold blue');
        logMsg( $LOG_INFO, "Checking Relationship Status for $strHANASID" );
        print color('reset');
        $strUser = $arrCustomerDetails[$i][1];
        $strSVM  = $arrCustomerDetails[$i][2];

    }
    else {
        logMsg( $LOG_INFO, "No data entered for SID" . ( $i + 1 ) . "  Skipping!!!" );
        next;
    }

    # get volume(s) to take a snapshot of
    runGetSnapmirrorRelationships();
    displayArray();

    runClearSnapMirrorRelationships();
}

# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "Command completed successfully." );

# time to exit
runExit($ERR_NONE);
