#!/usr/bin/perl
use strict;
use warnings;
use JSON;
use JIRA::Client;
use Data::Dumper;
use DBI;
use LWP::UserAgent;
use Encode qw(decode encode);
use Carp;

my $username='user'; my $passw0rd='password'; #Domain credentials
my $users={}; #The hash-ref of e-mail->IRM user name

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME}=0;
our $dbh1 = DBI->connect('dbi:mysql:database=irmdb;host=localhost','user','password',{AutoCommit=>1,RaiseError=>1,PrintError=>0});

sub get_issue { #retrieves reference to the issue nested data structure
  #get_issue(<issue_key>), for example, get_issue('EO-218')
  my $issueid=shift;
  my $json = JSON->new->allow_nonref; my $ua = new LWP::UserAgent;
  my $req = new HTTP::Request 'GET','https://jira.rambler-co.ru/rest/api/2/issue/'.$issueid;
  $req->authorization_basic($username, $passw0rd);
  my $res = $ua->request($req); my $json_text=$res->content; my $perl_scalar;
  eval {
    $perl_scalar = $json->decode( $json_text ); 
  };
  if ($@) {
    open (ERRORMSG, '>ERRORMSG.txt'); print ERRORMSG $json_text; close (ERRORMSG);
    $perl_scalar=undef;
  }
  return $perl_scalar;
}

sub update_issue {#updates Jira issue
  #update_issue(<issue_key>,<JSON-text>), for example, update_issue('EO-218',$data)
  my $id=shift; my $content=shift;
  my $header = HTTP::Headers->new(
       Content_Type => 'Content-Type: application/json',
       Content_Base => 'https://jira.rambler-co.ru/');
  my $ua = new LWP::UserAgent; my $req = new HTTP::Request 'POST','https://jira.rambler-co.ru/rest/api/2/issue/'.$id.'/editmeta',$header,$content;
  $req->authorization_basic($username, $passw0rd);
  my $res = $ua->request($req); print Dumper($res);
}

sub get_irm_comments { #retrieves reference to the array containing IRM comments to the issue
  my $issueid=shift; my $comments=[];
  my $query="SELECT * FROM irmdb.followups WHERE tracking=$issueid";
  #print "$query\n";
  my $sth = $dbh1->prepare("$query"); $sth->execute();
  while (my $row = $sth->fetchrow_hashref) {
    my $contents=$row->{'contents'}; push @$comments,$contents;
  }
  $sth->finish();
  return $comments;
}

sub jira_time { #converts data from jira format to common one
  my $time=shift; my $converted_time;
  if ($time=~/(\S+)T(\S+)\./) {
    $converted_time="$1 $2";
  }
  return $converted_time;
}

sub utf8decode {#wrapper for UTF8->Unicode decoder
  my $utf8_text=shift;
  my $unicode_text=decode('UTF-8',$utf8_text,Encode::FB_CROAK);
  return $unicode_text;
}

sub sync_tickets {#synchronizes ticket descriptions and jira comments with IRM ones
  my $irmcomments=shift; my $jira_ticket=shift; my $trackingid=shift; my $ticket_id=$$jira_ticket{'key'}; 
  my $comment; my $followup; my $jiracomments=$$jira_ticket{'fields'}{'comment'}{'comments'}; my $issueid=$$jira_ticket{'id'};
  foreach $comment (@$jiracomments){
    my $body=queryCleaner(utf8decode('<p>'.$$comment{'body'}.'</p><p>'.'JIRA id:'.$$comment{'id'}.'</p>')); my $flag=1;
    foreach $followup (@$irmcomments){
      if ($followup=~/JIRA\sid:$$comment{'id'}/m) {
        $flag=0;
      }
    }
    if ($flag) {
      my $followup_time=jira_time($$comment{'created'}); my $author=$$users{$$comment{'updateAuthor'}{'emailAddress'}};
      my $query="INSERT INTO irmdb.followups (tracking,date,author,contents) VALUES ($trackingid,'$followup_time','$author','$body')";
      print "$query\n";
      my $sth = $dbh1->prepare("$query"); $sth->execute(); $sth->finish();
    }
  }
  my $query="SELECT * FROM irmdb.tracking WHERE ID=$trackingid"; my $contents;
  my $sth = $dbh1->prepare("$query"); $sth->execute();
  while (my $row = $sth->fetchrow_hashref) {
    $contents=$row->{'contents'};
  }
  $sth->finish();
  unless ($contents=~/JIRA id:$issueid/m) {
    $contents=~s/'//g; print "$contents\n";
    my $hyperlink='<a href="https://jira.rambler-co.ru/browse/'.$ticket_id.'">'.$ticket_id.'</a>';
    $contents=queryCleaner(decode('UTF-8',$contents.'<p>'.$hyperlink.'</p><p>JIRA id:'.$issueid.'</p>',Encode::FB_CROAK));
    $query="UPDATE tracking SET contents='$contents' WHERE id=$trackingid";
    print "$query\n";
    $sth = $dbh1->prepare("$query"); $sth->execute(); $sth->finish();
  }
}

sub get_server_info {#retrieves all info about server location via a hash-ref
  my $server_id=shift; my $info={'ID'=>$server_id};
  my $query="
    SELECT 
        computers.id,
        computers.name AS 'servername',
        computers.inv_number AS 'invent',
        computers.serial,
        computers.rack_id,
        computers.rack_unit,
        computers.box_unit,
        racks.id,
        racks.name AS 'rackname',
        racks.location_id,
        locations.alias,
        computer_status.name AS 'status'
    FROM
        computers
            LEFT JOIN
        racks ON computers.rack_id = racks.id
            LEFT JOIN
        locations ON racks.location_id = locations.id
            LEFT JOIN
        computer_status ON computers.status_id=computer_status.id
    WHERE
        computers.id  = $server_id";
  my $sth = $dbh1->prepare("$query"); $sth->execute();
  while (my $row = $sth->fetchrow_hashref) {
    $$info{'location'}=$row->{'alias'};
    $$info{'rack'}=$row->{'rackname'};
    $$info{'name'}=$row->{'servername'};
    $$info{'invent'}=$row->{'invent'};
    $$info{'rack_unit'}=$row->{'rack_unit'};
    $$info{'box_unit'}=$row->{'box_unit'};
    $$info{'serial'}=$row->{'serial'};
    $$info{'status'}=$row->{'status'};
  }
  $sth->finish();  
  return $info;
}

sub align {
  my $string=shift; my $len=shift;
  return $string." "x($len-length($string));
}

sub irmc_like {#retrieves formatted information about server like irmc does.
  my $server=shift;
  while (my($key,$value)=each %$server) {
    unless (defined($$server{$key})) {
      $$server{$key}=" ";
    }
  }
  my $irmc_string="ID  |".align('Name',40)."|Rack   |Un|B |Serial            |Inv       |Loc|Sta\n".
  align($$server{'ID'},4)."|".align($$server{'name'},40)."|".align($$server{'rack'},7)."|".align($$server{'rack_unit'},2).
  "|".align($$server{'box_unit'},2)."|".align($$server{'serial'},18)."|".align($$server{'invent'},10)."|".align($$server{'location'},3).
  "|".align($$server{'status'},3);
}

sub get_tracking_server {#retrieves server ID tracking by issue
  my $irm_ticket=shift; my $computer;
  my $query="SELECT * FROM tracking WHERE ID=$irm_ticket";
  my $sth = $dbh1->prepare("$query"); $sth->execute();
  while (my $row = $sth->fetchrow_hashref) {
    $computer=$row->{'computer'};
  }
  return $computer;
}

sub convert_status {
  my $status=shift; my $converted_status;
  if (($status==1) || ($status==10030) || ($status==110016) || ($status==3) || ($status==4)) {
    $converted_status='active';
  } elsif (($status==10010) || ($status==5) || ($status==10006) || ($status==6)) {
    $converted_status='complete';
  } else {
    $converted_status='new';
  }
  return $converted_status;
}

sub queryCleaner { #removes any invalid characters from a string
  my $sourceString=shift;
  $sourceString=~ s/'//g;
  return $sourceString;
}


{
  my $name; my $email;
  my $query="SELECT * FROM users";
  my $sth = $dbh1->prepare("$query"); $sth->execute();
  while (my $row = $sth->fetchrow_hashref) {
    $name=$row->{'name'}; $email=$row->{'email'}; @$users{$email}=$name;
  }
  $sth->finish();
}

my $jira = JIRA::Client->new('https://jira.rambler-co.ru', $username, $passw0rd); #Connection to jira
print "Connection established\n";

$jira->set_filter_iterator('EO.team');
my $issue = eval { $jira->getIssue('EO-1600') };
die "Can't getIssue(): $@" if $@;
print Dumper(get_issue('EO-1600'));

my $failures=0; my $issueNumber=0; my $faultCount=0;

#=pod
while ((++$issueNumber) && ($faultCount<100)) {
  my $issue = eval { $jira->getIssue("EO-$issueNumber") };
  if ($@) {
    ++$faultCount;
    print "Can't getIssue(): $@\n";
    next;
  } else {
    $faultCount=0;
  }
  my $summary=$$issue{'summary'}; my $key=$$issue{'key'}; print "Processing $key\n";
  my $perl_scalar=get_issue($key); 
  unless (defined($perl_scalar)) {
    print "The query for $key was unsuccessful, let's try again\n";
    $failures++; redo;
  }
  #my $fields=$$perl_scalar{'fields'}{'comment'}{'comments'}; 
  my $assignee=undef;
  if (defined($$perl_scalar{'fields'}{'assignee'})) {
    $assignee=$$perl_scalar{'fields'}{'assignee'}{'emailAddress'};
  }
  if ($summary=~m/^\[eo\] IRM: new job ([0-9]+)/) {
    my $irm_ticket=$1; print "$$issue{'summary'}\n"; my $actualstatus=convert_status($$issue{'status'});
    print "The ticket $$issue{'key'} will be processed\n";
    print "ticket id is $irm_ticket\n";
    my $description=$$perl_scalar{'fields'}{'description'}; my $summary=$$perl_scalar{'fields'}{'summary'};
    sync_tickets(get_irm_comments($irm_ticket),$perl_scalar,$irm_ticket);
    if (defined($assignee)) {
      print "Issue $key was assigned to $assignee aka $$users{$assignee}\n";
      my $query="UPDATE irmdb.tracking SET status='$actualstatus',assign='$$users{$assignee}' WHERE ID='$irm_ticket'"; #print "$query\n";
      my $sth = $dbh1->prepare("$query"); $sth->execute(); $sth->finish();
    } else {
      my $query="UPDATE irmdb.tracking SET status='$actualstatus' WHERE ID='$irm_ticket'";
      my $sth = $dbh1->prepare("$query"); $sth->execute(); $sth->finish();
    }
=pod
    if(defined($description) && $description=~m/IRM info:/){
      print "**********************************************************************\n";
      my $server=get_server_info(get_tracking_server($irm_ticket));
      $description=utf8decode($description."\nIRM info:\n".irmc_like($server)."\n");
      $summary=utf8decode($summary." in ".$$server{'location'}); print "$summary\n";
      print "**********************************************************************\n";
      print "$description\n";
      $issue=$jira->update_issue($key, 
        {
          summary=>$summary,
          description =>$description
        }
      );
    }
=cut      
  }
}
#=cut

print "There were $failures failures\n";
$dbh1->disconnect;