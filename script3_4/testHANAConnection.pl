#!/usr/bin/perl -w
#
# Copyright (C) 2017 Microsoft, Inc. All rights reserved.
# Specifications subject to change without notice.
#
# Name: testHANAConnection.pl
# Date 05/15/2018
my $version = "3.4";    #current version number of script

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
use Term::ANSIColor;

#number of allowable SIDs. Number entered is one less than actual.. i.e if allowing 4 SIDs, then 3 is entered
my $numSID       = 9;
my $detailsStart = 11;

#Usage:  This script is used to test a customer's connection to the HANA database to ensure it is working correctly before attemping to run the script.
#
# Error return codes -- 0 is success, non-zero is a failure of some type
my $ERR_NONE = 0;
my $ERR_WARN = 1;

# Log levels -- LOG_INFO, LOG_CRIT, LOG_WARN.  Bitmap values
my $LOG_INFO = 1;    #standard output to file or displayed during verbose
my $LOG_CRIT = 2;    #displays only critical output to console and log file
my $LOG_WARN = 3;    #displays any warnings to console and log file

# Global parameters
my $exitWarn = 0;
my $exitCode;

my $verbose = 1;

#
# Global Tunables

#DO NOT MODIFY THESE VARIABLES!!!!
my @arrOutputLines;                   #Keeps track of all messages (Info, Critical, and Warnings) for output to log file
my @fileLines;                        #Input stream from HANABackupCustomerDetails.txt
my @strSnapSplit;
my @arrCustomerDetails;               #array that keeps track of all inputs on the HANABackupCustomerDetails.txt
my $strPrimaryHANAServerName;         #Customer provided IP Address or Qualified Name of Primay HANA Server.
my $strPrimaryHANAServerIPAddress;    #Customer provided IP address of Primary HANA Server
my $filename = "HANABackupCustomerDetails.txt";
my $strUser;                          #Microsoft Operations provided storage user name for backup access
my $strSVM;                           #IP address of storage client for backup
my $strHANANumInstance;               #the two digit HANA instance number (e.g. 00) the customer uses when installing HANA SIDs
my $strHANAAdmin;                     #Hdbuserstore key customer sets for paswordless access to hdbsql
my $intMDC;                           #Boolean for determining whether MDC environment is detected. 1 - Yes, 0 - No
my $sshCmd = '/usr/bin/ssh';          #typical location of ssh on SID
my $strHANASID;                       #The customer entered HANA SID for each iteration of SID entered with HANABackupCustomerDetails.txt
my $strHANAStatusCmdV1;               #generated command for HANA Version 1 to test access by requesting HANA DB status
my $strHANAStatusCmdV2;               #generated command for HANA Version 2 to test access by requesting HANA DB status

my $strHANAVersion;                   #HANA Major Version Number
my $strHANARevision;                  #HANA Revision release Number. Currently necessary to determine if HANA 2.0 install suports both MDC and HANA Snapshot

my $outputFilename = "";              #Generated filename for scipt output
my $HSR            = 0;               #used within only scripts, otherwise flagged to zero. **not used in this script**

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
    return (qq("$sshCmd" -l $strUser $strSVM 'set -showseparator ","; $strShellCmd' 2>&1"));
}

#
# Name: runCheckHANAVersion()
# Func: Checks version of HANA to determine which type of hdbsql commands to use
#
sub runCheckHANAVersion {
    my $strDirectory1     = '/hana/shared/' . $strHANASID . '/global/hdb/mdc';
    my $strDirectory2     = '/hana/shared/' . $strHANASID . '/' . $strHANASID . '/global/hdb/mdc';
    my $strHANAVersionCMD = './hdbsql -n ' . $strPrimaryHANAServerIPAddress . ' -i ' . $strHANANumInstance . ' -U ' . $strHANAAdmin . ' "select version from sys.m_database"';
    my $strHANAVersionTemp;
    my @arrHANAVersion;

    #first check whether MDC environment or not
    if ( -d $strDirectory1 or -d $strDirectory2 ) {
        $intMDC = 1;
        print color('bold green');
        logMsg( $LOG_INFO, "Detected MDC environment for $strHANASID." );
        print color('reset');
    }
    else {
        $intMDC = 0;
        print color('bold green');
        logMsg( $LOG_INFO, "Detected non-MDC environment for $strHANASID." );
        print color('reset');
    }

    logMsg( $LOG_INFO, "Checking HANA Version with command: \"$strHANAVersionCMD\" ..." );
    my @out = runShellCmd($strHANAVersionCMD);
    if ( $? ne 0 ) {

        logMsg( $LOG_WARN, "Please check the following:" );
        logMsg( $LOG_WARN, "HANA Instance is up and running." );
        logMsg( $LOG_WARN, "In an HSR Setup, this script will not function on current secondary node." );
        logMsg( $LOG_WARN, "hdbuserstore user command was executed with root" );
        logMsg( $LOG_WARN, "Backup user account created in HANA Studio was made under SYSTEM" );
        logMsg( $LOG_WARN, "Backup user account and hdbuserstore user account are case-sensitive" );
        logMsg( $LOG_WARN, "The correct host name and port number are used" );
        logMsg( $LOG_WARN, "The port number in 3(" . $strHANANumInstance . ")15 [for non-MDC] and 3(" . $strHANANumInstance . ")13 [for MDC] corresponds to instance number of " . $strHANANumInstance . " when creating hdbuserstore user account" );
        logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
        runExit($exitWarn);
    }
    else {
        $strHANAVersionTemp = $out[1];
        $strHANAVersionTemp =~ s/\"//g;
        logMsg( $LOG_INFO, "Version: $strHANAVersionTemp" );
        @arrHANAVersion  = split( /\./, $strHANAVersionTemp );
        $strHANAVersion  = $arrHANAVersion[0];
        $strHANARevision = $arrHANAVersion[2];
        if ( substr( $strHANARevision, 0, 1 ) eq 0 ) {
            $strHANARevision = substr( $strHANARevision, 1, 2 );
        }
    }
}

#
# Name: runCheckHANAStatus()
# Func: Create the HANA snapshot
#
sub runCheckHANAStatus {
    print color('bold cyan');
    logMsg( $LOG_INFO, "**********************Checking HANA status**********************" );
    print color('reset');

    # Create a HANA database username via HDBuserstore
    if ( defined($strHANAVersion) ) {
        if ( $strHANAVersion eq 1 ) {
            my @out = runShellCmd($strHANAStatusCmdV1);
            logMsg( $LOG_INFO, $strHANAStatusCmdV1 );
        }
        if ( $strHANAVersion eq 2 ) {
            my @out = runShellCmd($strHANAStatusCmdV2);
            logMsg( $LOG_INFO, $strHANAStatusCmdV2 );
        }
    }
    else {
        logMsg( $LOG_WARN, "Please check the following:" );
        logMsg( $LOG_WARN, "HANA Instance is up and running." );
        logMsg( $LOG_WARN, "In an HSR Setup, this script will not function on current secondary node." );
        logMsg( $LOG_WARN, "hdbuserstore user command was executed with root" );
        logMsg( $LOG_WARN, "Backup user account created in HANA Studio was made under SYSTEM" );
        logMsg( $LOG_WARN, "Backup user account and hdbuserstore user account are case-sensitive" );
        logMsg( $LOG_WARN, "The correct host name and port number are used" );
        logMsg( $LOG_WARN, "The port number in 3(" . $strHANANumInstance . ")15 [for non-MDC] and 3(" . $strHANANumInstance . ")13 [for MDC] corresponds to instance number of " . $strHANANumInstance . " when creating hdbuserstore user account" );
        logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
        runExit($exitWarn);

    }

    if ( $? ne 0 ) {
        if ( $strHANAVersion eq 1 ) {
            logMsg( $LOG_WARN, "HANA check status command '" . $strHANAStatusCmdV1 . "' failed: $?" );
        }
        if ( $strHANAVersion eq 2 ) {
            logMsg( $LOG_WARN, "HANA check status command '" . $strHANAStatusCmdV2 . "' failed: $?" );
        }
        logMsg( $LOG_WARN, "Please check the following:" );
        logMsg( $LOG_WARN, "HANA Instance is up and running." );
        logMsg( $LOG_WARN, "In an HSR Setup, this script will not function on current secondary node." );
        logMsg( $LOG_WARN, "hdbuserstore user command was executed with root" );
        logMsg( $LOG_WARN, "Backup user account created in HANA Studio was made under SYSTEM" );
        logMsg( $LOG_WARN, "Backup user account and hdbuserstore user account are case-sensitive" );
        logMsg( $LOG_WARN, "The correct host name and port number are used" );
        logMsg( $LOG_WARN, "The port number in 3(" . $strHANANumInstance . ")15 [for non-MDC] and 3(" . $strHANANumInstance . ")13 [for MDC] corresponds to instance number of " . $strHANANumInstance . " when creating hdbuserstore user account" );
        logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
        runExit($exitWarn);
    }
    else {
        print color('bold green');
        logMsg( $LOG_INFO, "HANA status check successful." );
        print color('reset');
    }

}

#
# Name: runPrintFile()
# Func: Prints output from Logs and Warnings to log file
#

sub runPrintFile {
    my $myLine;
    my $date = localtime->strftime('%Y-%m-%d_%H%M');
    $outputFilename = "HANAStatus.$date.txt";
    my $existingdir = './statusLogs';
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
logMsg( $LOG_CRIT, "Executing Test HANA Connection Script, Version $version" );
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

    if ( $arrCustomerDetails[$i][0] and ( $arrCustomerDetails[$i][0] ne "Skipped" and $arrCustomerDetails[$i][0] ne "Omitted" ) ) {
        $strHANASID = uc $arrCustomerDetails[$i][0];
        print color ('bold blue');
        logMsg( $LOG_INFO, "Checking HANA Status for $strHANASID" );
        print color ('reset');
        $strHANANumInstance = $arrCustomerDetails[$i][3];
        $strHANAAdmin       = $arrCustomerDetails[$i][4];
        $strHANAStatusCmdV1 = './hdbsql -n ' . $strPrimaryHANAServerIPAddress . ' -i ' . $strHANANumInstance . ' -U ' . $strHANAAdmin . ' "\s"';
        $strHANAStatusCmdV2 = './hdbsql -n ' . $strPrimaryHANAServerIPAddress . ' -i ' . $strHANANumInstance . ' -d SYSTEMDB -U ' . $strHANAAdmin . ' "\s"';
    }
    else {
        logMsg( $LOG_INFO, "No data entered for SID" . ( $i + 1 ) . "  Skipping!!!" );
        next;
    }

    #check which version of HANA
    runCheckHANAVersion();

    # execute the HANA check status command
    runCheckHANAStatus();

    # if we get this far, we can exit cleanly
    logMsg( $LOG_INFO, "*****************HANA Access Verified!*************************" );
}

# time to exit
runExit($ERR_NONE);
