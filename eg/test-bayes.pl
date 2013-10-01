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

GetOptions(
    'data=s'        => \my $data,
    'help'          => \my $help,
    'fast'          => \my $fast,
    'maxsize=i'     => \my $maxsize,
    'namespace=s'   => \my $namespace,
    'precise'       => \my $precise,
    'seed=i'        => \my $seed,
    'trace'         => \my $trace,
    'train'         => \my $train,
) or pod2usage(-verbose => 1);
pod2usage(-verbose => 99)
    if $help
    or not $data;

$namespace  ||= 'newsgroups';
srand($seed ||= 42);

my %stopwords;
if ($precise) {
    require Lingua::StopWords;
    %stopwords = %{ Lingua::StopWords::getStopWords('en') };
}

my $tokenizer = \&tokenizer;
if ($fast) {
    die "Can't be both fast and precise (yet)\n"
        if $precise;

    require Text::SpeedyFx;
    my $sfx = Text::SpeedyFx->new($seed, 8);

    $tokenizer = sub { $sfx->hash($_[0]) };
}

my $bayes = Redis::NaiveBayes->new(
    correction  => 1.18e-38,
    namespace   => $namespace . ':',
    tokenizer   => $tokenizer,
);

my @files;
find {
    no_chdir    => 1,
    wanted      => sub {
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
            my $score = $confusion->{$x}{$y} || 0;
            printf '%5d', $score;
            $sum += $score;
        }
        printf " |%5d%5s = %s\n", $sum, $i++, $x;
    }

    return;
}

sub tokenizer {
    my ($input) = @_;
    my %occurs;
    while ($input =~ m{(\w{3,})}gsx) {
        my $token = lc $1;
        ++$occurs{$token}
            unless exists $stopwords{$token};
    }
    return \%occurs;
}

__DATA__
=pod

=head1 NAME

test-bayes.pl - run Naive Bayes & output the confusion matrix

=head1 SYNOPSIS

 $ perl test-bayes.pl --train --data 20news-bydate-train
 $ perl test-bayes.pl --data 20news-bydate-test

=head1 DESCRIPTION

Inspired on L<MAHOUT Twenty Newsgroups Classification Example|https://cwiki.apache.org/confluence/display/MAHOUT/Twenty+Newsgroups>
To prepare the dataset for the testing:

 wget http://people.csail.mit.edu/jrennie/20Newsgroups/20news-bydate.tar.gz
 tar xzf 20news-bydate.tar.gz

The output should look like:

     a    b    c    d    e    f    g    h    i    j    k    l    m    n    o    p    q    r    s    t
 -----------------------------------------------------------------------------------------------------+
   267    0    0    4    0    1    0    0    2    1    0    1    0    3    1   13    1    3    2   20 |  319    a = alt.atheism
     1  306    0   14   10   15    8    0    0    0    0    7   12    2   12    0    0    0    0    2 |  389    b = comp.graphics
     1   92   11  151   31   37   14    4    1    2    0   17   10    5    5    3    1    0    8    1 |  394    c = comp.os.ms-windows.misc
     0   13    2  293   27    5   15    0    0    0    1    3   32    0    1    0    0    0    0    0 |  392    d = comp.sys.ibm.pc.hardware
     0   17    1   17  309    0   12    1    2    1    0    3   13    5    3    0    0    0    1    0 |  385    e = comp.sys.mac.hardware
     0   71    2   10    1  285    5    3    2    0    0    5    4    2    4    0    1    0    0    0 |  395    f = comp.windows.x
     0    8    0   20    5    0  334   10    1    0    4    0    4    1    3    0    0    0    0    0 |  390    g = misc.forsale
     0    1    0    3    1    0   12  355   12    0    0    1    4    2    2    0    1    0    2    0 |  396    h = rec.autos
     0    1    0    0    0    0    3   10  381    0    0    0    2    1    0    0    0    0    0    0 |  398    i = rec.motorcycles
     1    0    0    1    1    0    3    2    2  362   11    1    0    4    3    0    2    0    3    1 |  397    j = rec.sport.baseball
     0    0    0    0    0    0    3    2    3    6  378    0    0    1    0    1    2    0    3    0 |  399    k = rec.sport.hockey
     1    3    0    2    3    1    3    3    0    1    0  367    2    1    3    0    5    0    1    0 |  396    l = sci.crypt
     1   17    0   24    7    0   11    3    4    0    0   20  289    8    6    0    0    1    1    1 |  393    m = sci.electronics
     1   10    0    2    1    0    6    6    6    2    0    1    9  330    7    1    2    1   10    1 |  396    n = sci.med
     2   12    0    2    1    3    1    1    0    0    0    1    5    8  354    0    0    0    4    0 |  394    o = sci.space
     5    3    0    0    0    0    0    0    0    0    1    0    1    3    2  366    1    0    3   13 |  398    p = soc.religion.christian
     0    1    0    0    0    0    1    0    2    0    0    3    1    3    0    0  324    1   18   10 |  364    q = talk.politics.guns
    10    1    0    0    0    0    1    0    1    0    1    2    0    1    1    1    2  340   14    1 |  376    r = talk.politics.mideast
     7    2    0    0    0    0    1    1    3    0    1    4    0    1   10    0   69    0  188   23 |  310    s = talk.politics.misc
    36    3    0    0    0    0    0    2    0    0    0    1    0    2    4   15    7    1   10  170 |  251    t = talk.religion.misc
 13477.06 KB @ 59.27 KB/s

=head1 OPTIONS

=over 4

=item C<--help>

This.

=item C<--data=DIRECTORY>

Directory with the dataset.
This is the only required parameter.

=item C<--fast>

Use L<Text::SpeedyFx> to get faster tokenization.
(can't be used in conjunction with C<--precise>)

=item C<--maxsize=KILOBYTES>

Randomly pick up to this size of data from the dataset directory.
Useful for quick estimation.

=item C<--namespace>

Redis namespace.
Default: C<newsgroups>

=item C<--precise>

Use L<Lingua::StopWords> to get more precise tokenization.
(can't be used in conjunction with C<--fast>)

=item C<--seed=INTEGER>

Seed for the random operations (shuffling of the dataset load order).
Default: 42

=item C<--trace>

Output the individual results to STDERR prior to building the confusion matrix.

=item C<--train>

Run the training step.

=back

=cut
