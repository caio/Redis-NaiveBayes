#!/usr/bin/env perl
use strict;
use utf8;
use warnings qw(all);

use File::Find;
use File::Slurp;
use Getopt::Long;
use List::Util qw(shuffle);
use Pod::Usage;
use Time::HiRes qw(gettimeofday tv_interval);

use Redis::NaiveBayes;

# https://cwiki.apache.org/MAHOUT/twenty-newsgroups.html
# http://people.csail.mit.edu/jrennie/20Newsgroups/20news-bydate.tar.gz

GetOptions(
    'data=s'        => \my $data,
    'help'          => \my $help,
    'maxsize=i'     => \my $maxsize,
    'namespace=s'   => \my $namespace,
    'seed=i'        => \my $seed,
    'trace'         => \my $trace,
    'train'         => \my $train,
) or pod2usage(-verbose => 1);
pod2usage(-verbose => 99)
    if $help
    or not $data;

$namespace //= 'newsgroups';
srand($seed // 42);

my $bayes = Redis::NaiveBayes->new(
    namespace   => $namespace . ':',
    tokenizer   => sub {
        my ($input) = @_;
        my %occurs;
        ++$occurs{lc($1)}
            while $input =~ m{(\w+)}gsx;
        return \%occurs;
    },
);

my @files;
find {
    no_chdir => 1,
    wanted => sub {
        my $file = $_;
        return
            if -d
            or not -r _
            or not -s _;

        push @files => $file;
    },
} => "$data/";

my (%confusion, %categories);
my $start = [gettimeofday];
my $total = 0;

$bayes->flush
    if $train;

for my $file (shuffle @files) {
    my $data = read_file $file;
    $total += length $data;

    last
        if $maxsize
        and $total > (2 ** 10) * $maxsize;

    my ($correct) = (split m{/}x, $file)[-2];
    ++$categories{$correct}; 
    
    if ($train) {
        $bayes->train($correct => $data);
    } else {
        my $ctg = $bayes->classify($data);
        ++$confusion{$correct}->{$ctg};
        print STDERR "$correct\t$ctg\n"
            if $trace;
    }
}

matrix(\%categories, \%confusion)
    unless $train;

$total /= 2 ** 10;
printf "%0.2f KB @ %0.2f KB/s\n",
    $total,
    $total / tv_interval($start, [gettimeofday]);

sub matrix {
    my ($categs, $confusion) = @_;
    my @categs = sort keys %{$categs};

    printf '%5s', chr(97 + $_) for 0 .. $#categs;
    print "\n";
    print '-' x (5 * @categs), '-+';
    print "\n";

    my $i = 'a';
    for my $x (@categs) {
        my $sum = 0;
        for my $y (@categs) {
            my $score = $confusion->{$x}{$y} // 0;
            printf '%5d', $score;
            $sum += $score;
        }
        printf "|%5d%5s = %s\n", $sum, $i++, $x;
    }

    return;
}

__DATA__
=pod

=head1 NAME

test-bayes.pl - run Naive Bayes & output the confusion matrix

=head1 SYNOPSIS

 $ perl test-bayes.pl --train --data 20news-bydate-train
 $ perl test-bayes.pl --data 20news-bydate-test

=head1 DESCRIPTION

...

=head1 OPTIONS

=over 4

=item C<--help>

This.

=back

=cut
