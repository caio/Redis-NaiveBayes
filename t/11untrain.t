use strict;
use warnings;
use Test::More;

use Redis::NaiveBayes;

eval {
    Redis->new;
    1;
} or do {
    plan skip_all => "No Redis instance running";
};

plan tests => 5;


sub tokenizer {
    my $input = shift;
    my @it = split(/\s/, lc $input);

    my %toks;
    $toks{$_}++ for @it;

    return \%toks;
}

# Make sure the tokenizer is not broken
my $out = tokenizer("hello Hello worLd");
is_deeply({ hello => 2, world => 1}, $out, "Basic word tokenizer");


my $ns = 'test:';
my $nb = Redis::NaiveBayes->new(
    namespace => 'test:',
    tokenizer => \&tokenizer,
);

# NOTE that this test uses the state set by t/10train.t

my $nb_out = $nb->untrain("good", "naive bayes is naive");

is_deeply({ naive => 2, bayes => 1, is => 1 }, $nb_out, "untrain() returns occurrences");

is_deeply($nb->_priors('good'), { naive => 1, but => 1, not => 1, too => 1 }, "Stats decreased/deleted after untrain");

$nb->untrain("bad", "bad doggie!");
my @labels = $nb->_labels;
ok(! grep { $_ eq 'bad' } @labels, "Empty label got removed from LABELS");
is_deeply($nb->_priors('bad'), {}, "Data from removed label got purged");
