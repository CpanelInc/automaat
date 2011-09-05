#!/usr/bin/perl

use strict;
use Fcntl ':flock';
use IPC::Open3 ();
use Symbol     ();
use POSIX qw(:signal_h :errno_h :sys_wait_h);
use IO::Select ();

my $working_dir = '/var/run/maatkit';
my $mk_path     = '';
my $mysql_dir   = '/var/lib/mysql';
my @ignore      = qw( ); # e.g. ( dbname.tablename )
my @skip_dbs    = qw( ); # e.g. ( dbname );
my %print       = ( 'notices'  => 0,
                    'warnings' => 1,
                    'debug'    => 0 );
my $timeout     = 300;       #In seconds
my $max_length  = 1024*1024; #In bytes, 1024*1024=1 megabyte
my @mk_options  = ( ); #Additional mk-table-sync options

#########STOP EDITING HERE###########
$SIG{'CHLD'} = \&reaper;

my %children = ();
my %timedout = ();

#Parse some options
my %ignore = map { $_ => 1 } @ignore;
my %skip_dbs = map { $_ => 1 } @skip_dbs;

#Make sure we have a working directory
if(! -d $working_dir ) {
  print "Making working directory $working_dir\n";
  mkdir( $working_dir ) or die("Can't create working directory $working_dir: $!");
  chmod( 0700, $working_dir );
}

#If given a mk_path, make sure it ends with a /
if(   $mk_path 
   && $mk_path !~ /\/$/ ) {
  $mk_path .= '/';
}

#Make sure another maatkit isn't already running
my $lock;
if( ! -f "$working_dir/running" ) {
  open( $lock, '>', "$working_dir/running" ) or die("Can't open lock file. Is another maatkit already running?");
} else {
  open( $lock, '+<', "$working_dir/running" ) or die("Can't open lock file. Is another maatkit already running?");
}
flock( $lock, LOCK_EX|LOCK_NB ) or die("Can't establish lock file lock. Is another maatkit already running?");
truncate $lock, 0 or die("Can't truncate lockfile");
my $old_fd = select( $lock );
$| = 1;
print "$$\n";
$| = 0;
select( $old_fd );

#Get a list of database names
my @dbs = ();
my %skip_dbs = map { $_ => 1 } @skip_dbs;
opendir( my $mysql_dir_h, $mysql_dir ) or die("Can't open MySQL DIR $mysql_dir: $!");
while( my $file = readdir( $mysql_dir_h ) ) {
  $_ = $file; #Make the regexes a lil cleaner
  if( /^\.\.?$/ ) { next; }
  if( -d "$mysql_dir/$file" ) {
    if(   /^mk(.+)$/
       && -d "$mysql_dir/$1"
       && !exists($skip_dbs{$1}) ) {
     print "DEBUG: Adding $1 to the list of DBs\n" if( $print{'debug'} );
     push( @dbs, $1 );
    }
  }
}
closedir( $mysql_dir_h );

#Check the checksums for each one
foreach my $db ( @dbs ) {
  print "DEBUG: Working on $db\n" if( $print{'debug'} );
  my ( $mk_in, $mk_out );
  my $mk_err = Symbol::gensym;
  open( my $out, '>', "$working_dir/$db.sql" );
  local $SIG{'ALRM'} = \&mk_timeout;
  alarm($timeout);
  my $pid = IPC::Open3::open3( $mk_in,
                               $mk_out,
                               $mk_err,
                               $mk_path.'mk-table-sync',
                               "--databases=$db",
                               '--sync-to-master',
                               '--nocheck-slave',
                               '--print',
                               "--replicate=mk$db.checksum",
                               '--nounique-checks',
                               @mk_options,
                               'localhost' );
  $children{$pid} = $db;
  my $length = 0;
  my $sel    = new IO::Select;
  $sel->add($mk_out,$mk_err);
  while( my @ready = $sel->can_read) {
    foreach my $fh ( @ready ) {
      my $line = <$fh>;
      $_ = $line;
      if(!defined($line)) { #Must be EOF
        $sel->remove($fh);
        next;
      }
      if($fh == $mk_out ) {
        if(   /^(?:REPLACE INTO|DELETE FROM) `([A-Za-z0-9-_]+)`.`([A-Za-z0-9-_]+)`/
           && exists( $ignore{"$1.$2"} ) ) {
          my $short = $line;
          $short = substr($short, 0, 37)."..." if(length($short)>40);
          print "NOTICE: Skipping because this table is in the ignore list: $short\n" if($print{'notices'});
          next;
        }
        $length += length($line);
        if( $length > $max_length ) {
          print {$out} "-- Warning: Maatkit generated more than ".$length." bytes of output. Maatkit wanted to give more, but we're stopping here\n";
          kill(15,$pid);
        } else {
          print {$out} $line;
        }
      } elsif($fh == $mk_err ) {
        if(/^Can't make changes on the master because no unique index exists at \/usr\/bin\/mk-table-sync line \d+\.  while doing ([A-Za-z0-9-_]+)\.([A-Za-z0-9-_]+) on [A-Za-z0-9-.]+/) {
          if( !exists( $ignore{"$1.$2"} ) ) {
            print "WARNING: $1.$2 may have inconsistencies, but doesn't have a primary key, so we can't do anything about it. You can squelch this warning by adding this table name to \$ignore\n" if($print{'warnings'});
          } else {
            print "NOTICE: $1.$2 may have inconsistencies, but doens't have a primary key, so we can't do anything about it. This warning has been squelched to a notice\n" if($print{'notice'});
          }
        } elsif(/^open3: exec of ${mk_path}mk-table-sync/) {
          print "DEBUG: open3 returned $_" if( $print{'debug'} );
          die("Failed to run mk-table-sync");
        } else {
          print "($db) $line\n";
        }
      }
    }
  }
  alarm(0);
  if( $timedout{$pid} ) {
    print {$out} "-- Warning: Maatkit exceeded timoute of ${timeout}s for this database\n";
    delete($timedout{$pid});
  }
  close($out);
  if( -z "$working_dir/$db.sql" ) {
    unlink("$working_dir/$db.sql");
  }
}

#Time stamp file
open(my $ts, '>', "$working_dir/last-run");
print {$ts} time()."\n";
close($ts);

#clean up lock file
close($lock);
unlink("$working_dir/running");

#
# Signal subs
#
sub reaper {
  while( my $pid = waitpid(-1, &WNOHANG ) ) {
    if( $pid == -1 ) {
      #No child exited, ignore it
      return;
    } elsif( WIFEXITED( $? ) ) {
      my $exit_value  = $? >> 9;
      my $signal_num  = $? & 127;
      my $dumped_core = $? & 128;
      delete( $children{$pid} );
    } else {
      #False alarm on $pid
    }
  }
  $SIG{'CHLD'} = \&reaper; #Don't understand, but O'Reilly explains: in case of unreliable signals
}

sub mk_timeout {
  if( keys( %children ) ) {
    my ( $pid ) = keys( %children );
    print "WARNING: Maatkit took too long for $children{$pid}\n" if($print{'warnings'});
    $timedout{$pid} = 1;
    kill(15,$pid);
  }
}
