#!/usr/bin/perl
# This is my perl conversion of scytale's levitation project
# (http://github.com/scy/levitation).

use feature ':5.10';

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin";

use threads;
use threads::shared;
use Thread::Queue;

use Carp;

# don't overwrite CORE::length; thus only use -> no
use bytes;
no bytes;

use Regexp::Common qw(URI net);
use POSIX qw(strftime);
use List::Util qw(min first);
use Getopt::Long;
use Storable qw(thaw nfreeze);
use Digest::SHA1 qw(sha1);
use Time::Piece;

use PrimitiveXML;

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');


my $PAGES       = 10;
my $COMMITTER   = 'Levitation-pl <lev@servercare.eu>';
my $DEPTH       = 3;
my $DIR         = '.';
my $DB          = 'tc';
my $CURRENT;
my $HELP;
my $MAX_GFI     = 1000000;
my $GFI_CMD     = 'git fast-import --quiet';
my @NS;
my $ONE;

my $result = GetOptions(
    'max|m=i'       => \$PAGES,
    'depth|d=i'     => \$DEPTH,
    'tmpdir|t=s'    => \$DIR,
    'db=s'          => \$DB,
    'ns|n=s'        => \@NS,
    'current|c'     => \$CURRENT,
    'help|?'        => \$HELP,
    'one|o'         => \$ONE,
);
usage() if !$result || $HELP;

if ($DB eq 'tc') {
    eval { require TokyoCabinet; };
    if ($@) {
        print STDERR "cannot use TokyoCabinet, falling back to DB_File\nReason: $@\n";
        $DB = 'bdb';
    }
}
if ($DB eq 'bdb') {
    eval { require DB_File; };
    if ($@) {
        print STDERR "cannot use DB_File, terminating.\nReason: $@\n";
        $DB = undef;
    }
}
croak "couldn't load a persistent DB backend. Terminating." if not defined $DB;

# FIXME: would like to use Time::Piece's strftime(), but it returns the wrong timezone
my $TZ = $CURRENT ? strftime('%z', localtime()) : '+0000';

my $filename = "$DIR/levit.db";

my $stream = \*STDIN;

# put the parsing in a thread and provide a queue to give parses back through
my $queue = Thread::Queue->new();
my $thr = threads->create(\&thr_parse, $stream, $queue, $PAGES, \@NS);
my $pqueue = Thread::Queue->new();
my $persister = threads->create(\&persist, $pqueue, $filename, 'new', $DB);

my $domain = $queue->dequeue();
$domain = "git.$domain";

my $c_rev = 0;
my $max_id = 0;
open(my $gfi, '|-:utf8', $GFI_CMD) or croak "error opening pipe to 'git fast-import': $!";
while (defined(my $page = $queue->dequeue()) ) {
    # record current revision and page ids to be able to provide meaningful progress messages
    if ($page->{new}) {
        printf {$gfi} "progress processing page '%s:%s'  $c_rev / < $max_id\n", $page->{namespace}, $page->{title};
    }
    my $revid = $page->{revision_id};
    $max_id = $revid if $revid > $max_id;

    # and give the text to stdout, so git fast-import has something to do
    my $text = $page->{text} // "";
    my $len = bytes::length($text);

    print {$gfi} sprintf(qq{blob\ndata %d\n%s\n}, $len, $text);

    my $sha1 = do { use bytes; sha1(sprintf(qq{blob %d\x00%s}, $len, $text)) };

    # extract all relevant data
    my %rev = (
        user    => user($page, $domain),
        comment => ($page->{comment} // "") . ( $page->{minor} ? " (minor)" : ""),
        timestamp    => $page->{timestamp},
        pid     => $page->{id},
        ns      => $page->{namespace},
        title   => $page->{title},
        sha1    => $sha1
    );

    # persist the serialized data with rev id as reference
    $pqueue->enqueue([$revid, \%rev]);

    $c_rev++;
}
$pqueue->enqueue(undef);
# we don't need the worker thread anymore. The input can go, too.
$thr->join();
$persister->join();
close($stream);

exit(0) if $ONE;

my $CACHE = get_db($filename, 'read', $DB);

# go over the persisted metadata with a cursor
say {$gfi} "progress processing $c_rev revisions";

my $commit_id = 1;
while (my ($revid, $fr) = each %$CACHE){
    if ($commit_id % 100000 == 0) {
        say {$gfi} "progress revision $commit_id / $c_rev";
    }

    my $rev = thaw($fr);
    my $msg = "$rev->{comment}\n\nLevit.pl of page $rev->{pid} rev $revid\n";

    my @parts = ($rev->{ns});

    # we want sane subdirectories
    for my $i (0 .. min( length($rev->{title}), $DEPTH) -1  ) {
        my $c = substr($rev->{title}, $i, 1);
        $c =~ s{([^0-9A-Za-z_])}{sprintf(".%x", ord($1))}eg;
        push @parts, $c;
    }

    $rev->{title} =~ s{/}{\x1c}g;

    push @parts, $rev->{title};
    my $wtime = Time::Piece->strptime($rev->{timestamp}, '%Y-%m-%dT%H:%M:%SZ')->strftime('%s');
    my $ctime = $CURRENT ? time() : $wtime;

    print {$gfi} sprintf(
q{commit refs/heads/master
author %s %s +0000
committer %s %s %s
data %d
%s
M 100644 %s %s
},
    $rev->{user}, $wtime, $COMMITTER, $ctime, $TZ, bytes::length($msg), $msg, unpack('H*', $rev->{sha1}), join('/', @parts));

    $commit_id++;
}

untie %$CACHE;
say {$gfi} "progress all done! let git fast-import finish ....";

close($gfi) or croak "error closing pipe to 'git fast-import': $!";

# get an author string that makes git happy and contains all relevant data
sub user {
    my ($page, $domain) = @_;

    my $uid = $page->{userid};
    my $ip = $page->{ip};
    $ip = "255.255.255.255" if !defined $ip || $ip !~ $RE{net}{IPv4};
    my $uname = $page->{username} || $page->{userid} || $ip || "Unknown";

    my $email = defined $uid    ? sprintf("uid-%s@%s", $uid, $domain)
              : defined $ip     ? sprintf("ip-%s@%s", $ip, $domain)
              :                   sprintf("unknown@%s", $domain);

    $email = sprintf ("%s <%s>", $uname // $ip, $email);
    return $email;
}

# open the wanted DB interface, with the desired mode, configure it
# and return a tied hash reference.
sub get_db {
    my ($filename, $mode, $option) = @_;


    if ($option eq 'tc') {
        return get_tc_db($filename, $mode);
    }
    elsif ($option eq 'bdb') {
        return get_bdb_db($filename, $mode);
    }
}

sub get_tc_db {
    my ($filename, $mode) = @_;

    
    my %t;
    if ($mode eq 'new') {
        # use TokyoCabinet BTree database as persistent storage
        my $c = "TokyoCabinet::BDB"->new()                                    or croak "cannot create new DB: $!";
        my $tflags = $c->TLARGE|$c->TDEFLATE;
        my $mflags = $c->OWRITER|$c->OCREAT|$c->OTRUNC;
        # sort keys as decimals
        $c->setcmpfunc($c->CMPDECIMAL)                                      or croak "cannot set function: $!";
        # use a large bucket
        $c->tune(128, 256, 3000000, 4, 10, $tflags)                         or croak "cannot tune DB: $!";
        $c->open($filename, $mflags)                                        or croak "cannot open DB: $!";
        $c->close()                                                         or croak "cannot close DB: $!";
        tie %t, "TokyoCabinet::BDB", $filename, "TokyoCabinet::BDB"->OWRITER()  or croak "cannot tie DB: $!";
    }
    elsif ($mode eq 'write') {
        tie %t, "TokyoCabinet::BDB", $filename, "TokyoCabinet::BDB"->OWRITER()  or croak "cannot tie DB: $!";
    }
    elsif ($mode eq 'read') {
        tie %t, "TokyoCabinet::BDB", $filename, "TokyoCabinet::BDB"->OREADER()   or croak "cannot tie DB: $!";
    }
    return \%t;
}

sub get_bdb_db {
    my ($filename, $mode) = @_;

    $DB_File::DB_BTREE->{compare} = sub { $_[0] <=> $_[1] };

    my %t;
    my $mflags;
    if ($mode eq 'new') {
        $mflags = DB_File::O_RDWR()|DB_File::O_TRUNC()|DB_File::O_CREAT();
    }
    elsif ($mode eq 'write') {
        $mflags = DB_File::O_RDWR();
    }
    elsif ($mode eq 'read') {
        $mflags = DB_File::O_RDONLY();
    }
    tie %t, 'DB_File', $filename, $mflags, undef, $DB_File::DB_BTREE    or croak "cannot open DB: $!";
    return \%t;
}

# parse the $stream and put the result to $queue
sub thr_parse {
    my ($stream, $queue, $MPAGES, $MNS) = @_;
    my $revs = PrimitiveXML->new(handle => $stream);

    # give the site's domain to the boss thread
    my (undef, undef, $domain) = ($revs->{base} =~ $RE{URI}{HTTP}{-keep});
    $queue->enqueue($domain);
    
    my $c_page = 0;
    my $current = "";
    while (my $rev = $revs->next) {
        next if @$MNS && !first { $rev->{namespace} eq $_ } @$MNS;
        # more than max pages?
        if ($current ne $rev->{id}) {
            $current = $rev->{id};
            $c_page++;
            $rev->{new} = 1;
            last if $MPAGES > 0 && $c_page > $MPAGES;
        }
        # make threads::shared happy (initializes shared hashrefs);
        while ($queue->pending() > 1000) {
            threads->yield();
        }

        $queue->enqueue($rev);
    }

    # give an undef to boss thread, to signal "we are done"
    $queue->enqueue(undef);
    return;
}

sub persist {
    my ($queue, $file, $method, $config) = @_;
    my $CACHE = get_db($file, $method, $config);
    while (defined( my $elt = $queue->dequeue() )) {
        $CACHE->{"$elt->[0]"} = nfreeze($elt->[1]);
    }
    untie %$CACHE;
    undef %$CACHE;
    return 1;
}


sub usage {
    use File::Basename;
    my $name = basename($0);
    say STDERR qq{
$name - import MediaWiki dumps

Usage: bzcat pages-meta-history.xml.bz2 | \\
       $name [-m max_pages] [-t temp_dir|in_mem] [-d depth] [-h]

Options:
    -max
    -m max_pages    The number of pages (with all their revisions) to dump.
                    (default = 10)

    -tmpdir
    -t temp_dir     The directory where temporary files should be written.
                    If this is 'in_mem', try to hold temp files in memory.
                    (default = '.')

    -depth
    -d depth        The depth of the directory tree under each namespace.
                    For depth = 3 the page 'Actinium' is written to
                    'A/c/t/Actinium.mediawiki'.
                    (default = 3)

    -db (tc|bdb)    Define the database backend to use for persisting.
                    'tc' for Tokyo Cabinet is the default. 'bdb' is for
                    support via the standard Perl module DB_File;

    -ns
    -n namespace    The namespace(s) to import. The option can be given
                    multiple times. Default is to import all namespaces.

    -current
    -c              Use the current time as commit time. Default is to use
                    the time of the wiki revision. NOTICE: Using this option
                    will create repositories that are guaranteed not to be
                    equal to other imports of the same MediaWiki dump.

    -help
    -h              Display this help text.
};

    exit(1);
}

1;

