#!/usr/bin/perl
# This is my perl conversion of scytale's levitation project
# (http://github.com/scy/levitation).

use feature ':5.10';

use strict;
use warnings;
use Carp;
require bytes;

use Parse::MediaWikiDump;
use Regexp::Common qw(URI net);
use POSIX qw(strftime);
use POSIX::strptime;
use List::Util qw(min);
use Getopt::Long;
use TokyoCabinet;
use Storable qw(thaw nfreeze);

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');


my $PAGES       = 10;
my $COMMITTER   = 'Levitation-pl <lev@servercare.eu>';
my $DEPTH       = 3;
my $DIR         = '.';
my $HELP;

my $result = GetOptions(
    'max|m=i'       => \$PAGES,
    'depth|d=i'     => \$DEPTH,
    'tmpdir|t=s'    => \$DIR,
    'help|?'        => \$HELP,
);
usage() if !$result || $HELP;

my $TZ = strftime('%z', localtime());

my $filename = "$DIR/levit.db";

my $CACHE = TokyoCabinet::BDB->new() or die "db corrupt: new";
$CACHE->setcmpfunc($CACHE->CMPDECIMAL);
$CACHE->tune(128, 256, 32749, 4, 10, $CACHE->TLARGE|$CACHE->TDEFLATE);
$CACHE->open($filename, $CACHE->OWRITER|$CACHE->OCREAT|$CACHE->OTRUNC) or die "db corrupt: open";


my $stream = \*STDIN;

my $pmwd = Parse::MediaWikiDump->new;
my $revs = $pmwd->revisions($stream);

my (undef, undef, $domain) = ($revs->base =~ $RE{URI}{HTTP}{-keep});
$domain = "git.$domain";

my $c_page = 0;
my $c_rev = 0;
my $current = "";
my $max_id = 0;
while (defined(my $page = $revs->next)) {
    if ($current ne $page->id) {
        $current = $page->id;
        $c_page++;
        last if $PAGES > 0 && $c_page > $PAGES;
        printf("progress processing page '%s'  $c_rev / < $max_id\n", $page->title); 
    }

    my $revid = $page->revision_id;
    $max_id = $revid if $revid > $max_id;

    my %rev = (
        user    => user($page, $domain),
        comment => ($page->{DATA}->{comment} // "") . ( $page->minor ? " (minor)" : ""),
        timestamp    => $page->timestamp,
        pid     => $page->id,
        ns      => $page->namespace || "Main",
        title   => ($page->namespace && $page->title =~ /:/) ?  (split(/:/, $page->title, 2))[1] : $page->title,
    );

    $CACHE->put("$revid", nfreeze(\%rev)) or die "db corrupt: put";

    my $text = ${$page->text};
    print sprintf qq{blob\nmark :%s\ndata %d\n%s\n}, $revid, bytes::length($text), $text;
    $c_rev++;
}

close($stream);
$CACHE->close() or die "db corrupt: close";

my $commit_id = 1;

my %CACHE;
tie %CACHE, "TokyoCabinet::BDB", $filename, TokyoCabinet::BDB::OWRITER;
say "progress processing $c_rev revisions";

while (my ($revid, $fr) = each %CACHE ) {
    if ($commit_id % 100000 == 0) {
        say "progress revision $commit_id / $c_rev";
    }

    my $rev = thaw($fr);
    my $msg = "$rev->{comment}\n\nLevit.pl of page $rev->{pid} rev $revid\n";
    my @parts = ($rev->{ns});
    
    for my $i (0 .. min( length($rev->{title}), $DEPTH) -1  ) {
        my $c = substr($rev->{title}, $i, 1);
        $c =~ s{([^0-9A-Za-z_])}{sprintf(".%x", ord($1))}eg;
        push @parts, $c;
    }
    $rev->{title} =~ s{/}{\x1c}g;
    push @parts, $rev->{title};
    my $time = strftime('%s', POSIX::strptime($rev->{timestamp}, '%Y-%m-%dT%H:%M:%SZ'));

    print sprintf
q{commit refs/heads/master
author %s %s +0000
committer %s %s %s
data %d
%s
M 100644 :%d %s
},
    $rev->{user}, $time, $COMMITTER, time(), $TZ, bytes::length($msg), $msg, $revid, join('/', @parts);

    $commit_id++;
}

sub user {
    my ($page, $domain) = @_;

    my $uid = $page->userid;
    my $ip = $page->{DATA}->{ip};
    $ip = "255.255.255.255" if !defined $ip || $ip !~ $RE{net}{IPv4};
    my $uname = $page->username;

    my $email = defined $uid    ? sprintf("uid-%s@%s", $uid, $domain)
              : defined $ip     ? sprintf("ip-%s@%s", $ip, $domain)
              :                   "";
    $email = sprintf ("%s <%s>", $uname // $ip, $email);
    return $email;
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

    -help
    -h              Display this help text.
};

    exit(1);
}
