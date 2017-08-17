#!/usr/bin/perl -w
#
# 
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
# 
# Specifications subject to change without notice.
#
# Name: testHANAConnection.pl
# Version: 2.0
# Date 08/11/2017

use strict;
use warnings;
use Time::Piece;
use Date::Parse;
#Usage:  This script is used to test a customer's connection to the HANA database to ensure it is working correctly before attemping to run the script.
#



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
my @fileLines;
my @strSnapSplit;
my @customerDetails;
my $filename = "HANABackupCustomerDetails.txt";
my $sshCmd = '/usr/bin/ssh';


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
my $verbose = 1;
my $strHANAStatusCmd = './hdbsql -n '.$strHANANodeIP.' -i '.$strHANANumInstance.' -U ' . $strHANAAdmin . ' "\s"';
my $outputFilename = "";

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
# Name: runCheckHANAStatus()
# Func: Create the HANA snapshot
#
sub runCheckHANAStatus
{
			logMsg($LOG_INFO, "**********************Creating HANA status**********************");
			# Create a HANA database snapshot via HDBuserstore, key snapper
			my @out = runShellCmd( $strHANAStatusCmd );
			if ( $? ne 0 ) {
					logMsg( $LOG_WARN, "HANA check status command '" . $strHANAStatusCmd . "' failed: $?" );
          logMsg( $LOG_WARN, "Please check the following:");
          logMsg( $LOG_WARN, "hdbuserstore user command was executed with root");
          logMsg( $LOG_WARN, "Backup user account created in HANA Studio was made under SYSTEM");
          logMsg( $LOG_WARN, "Backup user account and hdbuserstore user account are case-sensitive");
          logMsg( $LOG_WARN, "The correct host name and port number are used");
          logMsg( $LOG_WARN, "The port number in 3(01)15 corresponds to instance number of 01 when creating hdbuserstore user account");
					logMsg( $LOG_WARN, "******************Exiting Script*******************************" );
					exit;
				} else {
					logMsg( $LOG_INFO, "HANA status check successful." );
			}

}

sub runPrintFile
{
	my $myLine;
	my $date = localtime->strftime('%Y-%m-%d_%H%M');
	$outputFilename = "HANA Status.$date.txt";
	my $existingdir = './statusLogs';
	mkdir $existingdir unless -d $existingdir; # Check if dir exists. If not create it.
	open my $fileHandle, ">>", "$existingdir/$outputFilename" or die "Can't open '$existingdir/$outputFilename'\n";
	foreach $myLine (@arrOutputLines) {
		print $fileHandle $myLine;


	}
	close $fileHandle;




}

# execute the HANA create snapshot command
runCheckHANAStatus();

# if we get this far, we can exit cleanly
logMsg( $LOG_INFO, "*****************All HANA nodes verified!*************************" );


runPrintFile();
# time to exit
runExit( $ERR_NONE );
