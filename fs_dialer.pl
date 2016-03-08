#!/usr/bin/perl

# load module
use DBI;
use strict;
use ESL;
use Data::Dumper;
use Digest::MD5; 
use LWP::Simple qw(get);
use JSON        qw(from_json);
use File::Fetch;


my $args = $#ARGV + 1;
if( $args < 1 ){
	die "We need the campaign to launch...\n";
}


my $campaign_id = shift;
my $gateway;
my $total_numbers = 0;
my $time_to_wait_after_calling_queue_max_calls = 5;
my @audio_files = ();
my @phone_list = ();


# Variables
my @ongoing_calls = ();


# Database Hanlders
my $dbh;
my $sth;


# FS Connect
my $con = new ESL::ESLconnection("127.0.0.1", "8021", "ClueCon");
die "Can't connect to freeSWITCH!\n" if $con->connected() != 1;


# DB Connect
#sub processEvent( $ );
sub getCampaignData( $ );
#sub updateCampaignData( $ );
#sub createCall( $$ );
#sub getDestiantionNumbers( $$ );
#sub getCall($);
#sub getCLIs( $$ );
#sub connect2pg();

connect2pg();

print "Connected\n";
print "Launching campaign ID: " . $campaign_id . "\n";

# Ask FS to send me all events related to calls.
$con->events("plain","CHANNEL_ANSWER CHANNEL_HANGUP_COMPLETE PLAYBACK_STOP");

my $event;

print "Getting campaing data\n";

my $url     = "http://localhost/api.php?campaing=" . $campaign_id;
my $decoded = from_json(get($url));

my $campaign_type = $decoded->{'campaing_type'};
my $outbound_provider = $decoded->{'outbound_provider'};
my $concurrent_calls = $decoded->{'concurrent_calls'};
my $time_between_calls = $decoded->{'time_between_calls'};
my $max_destination_retry = $decoded->{'max_destination_retry'};
my $outbound_caller_id = $decoded->{'outbound_caller_id'};
my $audio_array = $decoded->{'audio_array'};
my $phone_list_array = $decoded->{'phone_list_array'};

#print "dumper: " . Dumper( $decoded ) . "\n";

print "campaign_type: " . $campaign_type . "\n";
print "outbound_provider: " . $outbound_provider . "\n";
print "concurrent_calls: " . $concurrent_calls . "\n";
print "time_between_calls: " . $time_between_calls . "\n";
print "max_destination_retry: " . $max_destination_retry . "\n";
print "outbound_caller_id: " . $outbound_caller_id . "\n";
print "audio_array: " . $audio_array . "\n";

my $count=0; 
foreach my $item ( @{$audio_array} ) {
	print "===============================================================================================\n";

	print "\turl : " . $item->{'url'} . "\n";
	print "\tdur :" . $item->{'duration'} . "\n";
	print "\tid  :" . $item->{'id'} . "\n";
	
	my $ff = File::Fetch->new( uri => $item->{'url'} );
	$audio_files[$count] = $ff->fetch( to => '/tmp' );
	
	print "Audio file fetched to " . $audio_files[$count] . "\n";
	
	$count++; 
}

print "phone_list_array: " . $phone_list_array . "\n";
print "===============================================================================================\n";
foreach my $key ( keys %$phone_list_array ) {
	print "\t$key : " . $phone_list_array->{$key} . "\n"; 
	push @phone_list, $key;
}
print "===============================================================================================\n";

# Get Initial Queue Count...
print "Getting QueueCount...\n";
my $queue_count = getQueueCount($campaign_id);
print "Call count    : $queue_count\n";
print "Phone Numbers : " . scalar @phone_list . "\n";

while ( scalar @phone_list > 0 )
{
	foreach my $phone_number ( @phone_list ) {
		
		### If there are more calls going on than the max concurrent, we wait a while...	
		$queue_count = getQueueCount($campaign_id);

		while( $queue_count >= $concurrent_calls ){
			print "Waiting to sedn more calls...\n";
			$queue_count = getQueueCount($campaign_id);

			my $e = $con->recvEventTimed(1000);
			if ( $e ) {
				processEvent($e);
			}

			sleep 1;
		}
	
		printf( "Queue count: %s - Max Calls: %s\n", $queue_count, $concurrent_calls );
	

		print "\t--> Create call for destination $phone_number with caller-id: $outbound_caller_id via gateway $outbound_provider\n";

		my $call_uuid;
		if( $campaign_type eq 'message' )
		{
			$call_uuid = createCallForMessageType( $outbound_caller_id, $phone_number, $audio_files[0], $campaign_type );
		}else
		{
			$call_uuid = createCallForMultiMessageType( $outbound_caller_id, $phone_number, $campaign_type, $campaign_id, $audio_files[0], $audio_files[1], $audio_files[2] );
		}	
	
	
	
		sleep 1; #$time_between_calls * 0.5;
	}
}
#				my $call_uuid = createCall( $ref_clis->{'clgnum'}, $ref_destinations->{'cldnum'} );
#				$con->api("uuid_setvar","custom_uuid=" . $ref_clis->{'clgnum'} . "-" . $ref_destinations->{'cldnum'});
	
#		my $e = $con->recvEventTimed(1000);
#		if ( $e ) {
#			processEvent($e);
#		}

exit 0;
##########################################################################################




sub connect2pg(){
	# connect
	$dbh = DBI->connect("DBI:mysql:freeswitch;host=localhost", "root", "password",{'RaiseError' => 1});
}

sub createCallForMessageType($$) {

	####
	my $clgnum = shift;
	my $cldnum = shift;
	my $audiofile = shift;
	my $campaing_type = shift;

	my $unique_id = Digest::MD5::md5_base64( rand );

	if( defined( $con->api("create_uuid") ) )
	{

		my $uuid = $con->api("create_uuid")->getBody();
		print "UUID: $uuid\n";
		

		my $call_command = '{audio1=' . $audiofile . ',campaing_type=' . $campaign_id . ',originate_retries=0' .
			',originate_timeout=30,origination_callee_id_name=\'' . $campaign_id . '\',origination_caller_id_number=' . $clgnum .
#			'}sofia/external/' . $cldnum . ' 9999 XML public';
			'}user/' . $cldnum . ' 9999 XML public';

		print "call command: $call_command\n";
		my $result = $con->bgapi("expand originate $call_command"); #->getBody();
		print "Result: " . Dumper( $result->serialize("json") ) . "\n";

		if( !defined($result) ){
			die "Can't connect to FS!\n";
		}

		return $uuid;

	}else{

		return "";

	}
}

sub getCall($) {

	my $uuid = shift;
	my $sth = $dbh->prepare("select * from dialer.online_calls where uuid = '$uuid'");
	$sth->execute();
	print "rows: " . $sth->rows . "\n";
	my $ref = $sth->fetchrow_hashref();

	return $ref->{"duration"};
}


sub urldecode {
    my $s = shift;
    $s =~ tr/\+/ /;
    $s =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/eg;
    return $s;
}

sub execSql {
	my $sql = shift;
	my $sth = $dbh->prepare($sql) or die "Can't prepare SQL statement: $DBI::errstr\n";
	$sth->execute();
	if ( $sth->err  ){
		print "we got an error!\n";
		
	}
}

sub getQueueCount {
	print "getting queue count...";
	my $campaign_id = shift;
	my $sql = "SELECT count(*) as count FROM basic_calls where direction =  'outbound' and ( callee_name = $campaign_id or cid_name = $campaign_id )";
	my $sth = $dbh->prepare($sql) or die "Can't prepare SQL statement: $DBI::errstr\n";
	$sth->execute();
	my $ref = $sth->fetchrow_hashref();
	print "done.\n";

	return $ref->{"count"};
}

sub processEvent($){
	my $my_e = shift;
	my $ev_name = $my_e->getHeader("Event-Name");
	my $event_uuid = $my_e->getHeader("Caller-Unique-ID");

	my $event_clgnum = $my_e->getHeader("Caller-Caller-ID-Number");
	my $event_cldnum = $my_e->getHeader("Caller-Callee-ID-Number");

	my $custom_id = $event_clgnum . "-" . $event_cldnum;

	print "---> Got an event: $ev_name: ";
	print "Event: " . Dumper( $my_e->serialize("json") ) . "\n";

	if ( $ev_name eq 'CHANNEL_ANSWER' ) {

		print "------> Call answered: " . $custom_id . " \n";

	}elsif( $ev_name eq 'CHANNEL_HANGUP_COMPLETE' ){

		print "------> Call disconnected: $event_uuid -> " . $my_e->getHeader("Caller-Orig-Caller-ID-Number") . "-" . $my_e->getHeader("Caller-Caller-ID-Number") . "\n";
		printf( "datetime_start: %s\n", 	$my_e->getHeader("Event-Date-Local") ); 
		printf( "campaign_id: %s\n", 		$my_e->getHeader("variable_campaing_type") ); 
		printf( "cldnum: %s\n", 			$my_e->getHeader("variable_dialed_user") ); 
		printf( "clgnum: %s\n", 			$my_e->getHeader("Caller-Orig-Caller-ID-Number") ); 
		printf( "audio1: %s\n", 			$my_e->getHeader("variable_audio1") ); 
		printf( "audio2: %s\n", 			$my_e->getHeader("variable_audio2") ); 
		printf( "audio3: %s\n", 			$my_e->getHeader("variable_audio3") ); 
		printf( "dtmf_received: %s\n", 		$my_e->getHeader("Caller-Orig-Caller-ID-Number") ); 
		printf( "answered: %s\n", 			$my_e->getHeader("variable_endpoint_disposition") ); 
		printf( "duration: %s\n", 			$my_e->getHeader("variable_billsec") ); 

	}elsif( $ev_name eq 'PLAYBACK_STOP' ){
		print "------> Playback stopped: $event_uuid -> " . $my_e->getHeader("Caller-Orig-Caller-ID-Number") . "-" . $my_e->getHeader("Caller-Caller-ID-Number") . "\n";
		$con->api("uuid_setvar", $my_e->getHeader("Unique-ID") . " variable_playback_file " . $my_e->getHeader("Playback-File-Path") . "-" . $my_e->getHeader("Playback-Status") );

	}
}


