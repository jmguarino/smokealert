#!/usr/bin/perl
#
# SmokeAlertListener.pl - by Justin Guarino 
#
# NOTE! This was written for a particular master/slave installation of smokeping. Some modifications
# will likely be needed to use in
#
# This script is meant to be paired with SmokeAlertCron.pl and it takes over the responsibility
# of sending out notifications of packet loss. The default smokeping alerting allows for state 
# change triggered alerting without followup, and what ends up being continuous alerting about problem 
# hosts every five minutes. This seems too quiet in the instance of state changes and overly verbose
# in the case of continous loss from a downed host( especially since an alert is triggered from
# every slave probing a downed host as well as anywhere the downed host would be a slave). This
# script and the AlertCron are meant to email on state changes but also provide hourly reminders.
#
# 
# This script should be the "to" target of an alert in the *** ALERTS *** section
# of the smokeping config file.
#
# An example of how the alert should be defind in the config is as follows:
#   
#	*** Alerts ***
#	+AlertScript
#	to = | /***FullPathToScriptHere***/SmokeAlertListener.pl
#	type = loss
#	pattern = >0%
#	comment = external alert handling
# 

use strict;
use File::Copy qw(move);

# These 5 args are what Smokeping sends to the script.
my $alertName = shift;
my $target = shift;
my $lossPattern = shift;
my $rttPattern = shift;
my $hostname = shift;

mkdir '/dev/shm/smokeping' unless -d '/dev/shm/smokeping';

#Trim out leading "loss: " in string supplied from Smokeping.
(my $loss = $lossPattern) =~ s/loss: //;
#Make it more obvious if the host reporting loss is the master instance
if(index($target, "from") == -1){
	$target.=" [from master]";
}

my $timeStamp = getTime();

if(-e "/dev/shm/smokeping/$hostname"){
	appendToAlert();
}
else{
	createNewAlert();
}


sub createNewAlert()
{
	my $newAlert = "/dev/shm/smokeping/". $hostname;
	open(my $outfh, ">", $newAlert) || die "Couldn't open '".$newAlert."' for writing because: ".$!;
	flock($outfh, 2) || die "Couldn't lock file $newAlert for writing\n";
	print $outfh "\n" . $target . "\n" . $timeStamp . $loss . "\n";
	close($outfh) || die "Couldn't write file $newAlert \n";
}

sub appendToAlert()
{
	my $contAlert = "/dev/shm/smokeping/" . $hostname;
	open(my $infh, "<", $contAlert) || die "Couldn't open '". $contAlert."' for reading because: ".$!;
	flock($infh, 1) || die "Couldn't lock file $contAlert for reading \n";
	open(my $outfh, ">", "$contAlert.new") || die "Couldn't open '"."$contAlert.new"."' for writing because: ".$!;
	flock($outfh, 2) || die "Couldn't lock file $contAlert.new for writing\n";
	
	#The loop below checks if the host reporting loss is already in the alert file for the target hostname. 
	#If it is the new loss is appended below the hostname reporting loss to target, if not the hostname is 
	#added at the end of the file. It also retains only the last 12 reports of packet loss from a host.
	my $previousReport=0; 
	while(!eof $infh) {
		my $line = readline $infh;
		if($line eq "$target\n"){
			$previousReport=1;
			print $outfh $line;
			print $outfh $timeStamp . $loss . "\n";
			my $count = 1;
			$line = readline $infh;
			while($count <=11 && $line !~ /^\s/) {
				print $outfh $line;
				$count++;
				$line = readline $infh;
			}
		}
		elsif (index($line, "from") != -1) {
			print $outfh $line;
			my $count = 1;
			$line = readline $infh;
			while($count <=12 && $line !~ /^\s/){
				print $outfh $line;
				$count++;
				$line = readline $infh;
			}
		}
		if ($line =~ /^\s/) {
				print $outfh $line;
		}
	}
	if($previousReport==0){
		print $outfh "\n" . $target . "\n" . $timeStamp . $loss . "\n";
	}

	close($infh);
	close($outfh) || die "Couldn't write file $contAlert.new \n";
	move "$contAlert.new", $contAlert;
	
}

sub getTime()
{
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
    my $nice_timestamp = sprintf ( "%04d%02d%02d %02d:%02d:%02d  ",
                                   $year+1900,$mon+1,$mday,$hour,$min,$sec);
    return $nice_timestamp;
}