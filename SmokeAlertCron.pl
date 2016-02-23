#!/usr/bin/perl
#
# SmokeAlertCron.pl - by Justin Guarino
#
# NOTE! This script was intended for a specific implementation where the names of each target
# had a logical scheme to their naming which this fits. You will likely need to modify the regexes
# where the body is parsed to suite your needs
# 
# This script is meant to be paired with SmokeAlertListener.pl and it takes over the responsibility
# of sending out notifications of packet loss. The default smokeping alerting allows for state 
# change triggered alerting without followup, and what ends up being continuous alerting about problem 
# hosts every five minutes. This seems too quiet in the instance of state changes and overly verbose
# in the case of continuous loss from a downed host( especially since an alert is triggered from
# every slave probing a downed host as well as anywhere the downed host would be a slave). This
# script and the Listener are meant to email on state changes but also provide hourly reminders.
#
# This script should be added to the crontab and should likely be run every 5 minutes or so to provide
# reasonable response times for new notifications of packet loss.

use strict;
use Email::Send;
use Email::Simple;
use File::stat;
use Storable;

# This hash can be adjusted if we want to fine tune how noisy the alerts are. Each key corresponds to
# packet loss detected in a 5 minute period (20 pings every 5 minutes from smokeping) and the value maps 
# to how many reports of this loss is required before an alert is sent. If a key for a given percent
# is not in the hash a report is immediately generated (note: loss of 5% is ignored anyway as the script isn't 
# called by smokeping unless loss > 5%).
my %tolerance = ("10%" => 5);

my $alertHostFile = "/dev/shm/smokeping/alertinghosts";
my $lastAlertTimeFile = "/dev/shm/smokeping/lastalerttime";

opendir my $dir, "/dev/shm/smokeping" || die "No /dev/shm/smokeping directory";
my @files = readdir $dir;
closedir $dir;


my $currentTime = time;

my %alertingHosts;
my %toFrom;
my $lastAlertTime = 0;

#Read persistant data using Storable if it exists
if(-e $alertHostFile){
	%alertingHosts = %{retrieve $alertHostFile};
}
if(-e $lastAlertTimeFile){
	$lastAlertTime = ${retrieve $lastAlertTimeFile};
}

my $shouldSend = 0;

foreach my $hostFile(@files){
	#regex to check if filename in $dir above is valid IP or domain name
	if($hostFile =~ /^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$/
		|| $hostFile =~ /^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,6}$/){

		my $host = $hostFile;
		my $lastModified = (stat("/dev/shm/smokeping/$host")->mtime);

		#check if file hasn't been modified for 30min indicating no packet loss reported, if so clear alert
		if($currentTime-$lastModified >= 1800){
			_clearAlert($host);
		}
		elsif(!exists($alertingHosts{$host})){
			#Host not previously reported, evaluate if it should be added to alerting hosts based on 
			#whether or not packet loss reported is above tolerance
			my %lossLevels;
			my $aboveTolerance = 0;
			open(my $infh, "<", "/dev/shm/smokeping/$host") || die "Couldn't open /dev/shm/smokeping/$host for reading because: ".$!;
			flock($infh, 1) || die "Couldn't lock file /dev/shm/smokeping/$host for reading \n";
			foreach my $key (keys %tolerance){
				$lossLevels{$key}=0;
			}
			while(!eof $infh){
				my $line = readline $infh;
				if($line =~ /^\d/ && $line =~ /%\n$/){
					my @fields = split(" ", $line);
					$fields[2] =~ s/\n//;
					my $loss = $fields[2]; #Just for readability
					$lossLevels{$loss}+=1;
				}
			}
			close($infh);
			foreach my $key (keys %lossLevels){
				if(!exists($tolerance{$key})){
					$aboveTolerance = 1;
				}
				elsif($lossLevels{$key}>=$tolerance{$key}){
					$aboveTolerance = 1;
				}
			}

			if($aboveTolerance == 1){
				$alertingHosts{$host}=$currentTime;
				$shouldSend = 1;
			}
		}
	}
}

#Check if it has been 1 hr since alert email was sent, if so send another email
if($currentTime-$lastAlertTime >= 3600 && (scalar keys %alertingHosts) > 0) {
	$shouldSend = 1;
}

if($shouldSend == 1){
	_sendAlert();
	$lastAlertTime = $currentTime;
}

#Write persistant data using Storable
store \%alertingHosts, $alertHostFile;
store \$lastAlertTime, $lastAlertTimeFile;

sub _clearAlert($){
	my $hostname = shift;

	unlink "/dev/shm/smokeping/$hostname";
	delete $alertingHosts{$hostname};
}

sub _sendAlert()
{
	my $body;
	my $subject = "Smokeping has detected loss";

	foreach my $alertHost(keys %alertingHosts){
		my $host = $alertHost;
		open(my $infh, "<", "/dev/shm/smokeping/$host") || die "Couldn't open /dev/shm/smokeping/$host for reading because: ".$!;
		flock($infh, 1) || die "Couldn't lock file /dev/shm/smokeping/$host for reading \n";

		while(!eof $infh){
			my $line = readline $infh;
			if($line =~ /'***HTTPSPROBENAMEHERE***'/){
				$body .= "Lookup of ***DNSTargetHere*** failed using $host\n";
				$body .= $line;
				_eval_from($host, $line);
			}
			elsif($line =~ /'***HTTPSPROBENAMEHERE***'/){
				$body .= "HTTPS connection to $host failed\n";
				$body .= $line;
				_eval_from($host, $line);
			}
			elsif($line =~ /'***IPV4PROBENAMEHERE***/){
				$body .= "IPv4 ping failed to $host\n";
				$body .= $line;
				_eval_from($host, $line);
			}
			elsif($line =~ /'IPV6PROBENAMEHERE'/){
				$body .= "IPv6 ping failed to $host\n";
				$body .= $line;
				_eval_from($host, $line);
			}
			else{
				$body .= $line;
			}
		}
		close($infh);
		$body .= "\n\n";
	}
	
	my @problemHosts = 	_eval_Problem_Hosts();

	my $numHosts = @problemHosts;

	my $bodyTop = "";

	if($numHosts == 1){
		$subject = "Smokeping has detected loss on $problemHosts[0]";
		$bodyTop = "Loss on $problemHosts[0]\n See data below: \n\n";
	}
	elsif($numHosts > 1){  # $numHosts shouldn't be 0 but just in case there's a bug
		$subject = "Smokeping has detected loss on $numHosts hosts";
		foreach my $bodyTopHost (@problemHosts){
			$bodyTop .= "Loss on $bodyTopHost\n";
		}
		$bodyTop .= "See data below: \n\n";
	}


	my $mail = Email::Simple->create(
		header=> [
		From => 'smokealert@INSERTDOMAINHERE',
		To => 'INSERTTOADDRESSHERE', ###
		Subject => $subject,
		],
		body=> $bodyTop . $body . "\n\nThis alert was sent using /***FullDirectoryHere***/SmokeAlertCron.pl on ***HostNameHere***\n",
		);

	my $sender = Email::Send->new({ mailer => 'Email::Send::Sendmail' });
	my $result = $sender->send($mail->as_string);
}

sub _eval_from
{
	my $host = shift;
	my $line = shift;

	my @fromArray = split / /, $line;
	my $fromHost = $fromArray[2];
	$fromHost =~ s/\]\n//;

	$toFrom{$host}{$fromHost} = 1;
}

sub _eval_Problem_Hosts
{
	my @retProbHosts;

	while(%toFrom){
		my $topCount = 0;
		my @problemHosts;
		foreach my $fromRef (keys %toFrom){
			my $count = keys %{$toFrom{$fromRef}};
			if($count > $topCount){
				$topCount = $count;
				@problemHosts=();
				push @problemHosts, $fromRef;
			}
			elsif($count == $topCount){
				push @problemHosts, $fromRef;
			}
		}

		foreach my $probHost (@problemHosts){
			push @retProbHosts, $probHost;
			delete $toFrom{$probHost};

			foreach my $hostRef (keys %toFrom){
				if(exists($toFrom{$hostRef}{$probHost})){
					delete $toFrom{$hostRef}->{$probHost};
				}
				if(!keys %{$toFrom{$hostRef}}){
					delete $toFrom{$hostRef};
				}
			}
		}
	}
	return @retProbHosts;
}