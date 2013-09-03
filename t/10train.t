use strict;
use warnings;
use Test::More tests => 7;

use Redis::NaiveBayes;


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

# Start from a blank state
$nb->flush;

my $nb_out = $nb->train("good", "naive bayes is naive");
is_deeply({ naive => 2, bayes => 1, is => 1 }, $nb_out, "train() returns occurrences");

ok((grep { $_ eq 'good' } $nb->_labels), "Label added after training on empty state");

is_deeply($nb->_priors('good'), { naive => 2, bayes => 1, is => 1 }, "Stats initialized");

$nb->train("good", "but not too naive");
my @labels = $nb->_labels;
ok(@labels == 1, "Same label doesn't create another entry in the set");

is_deeply($nb->_priors('good'), { naive => 3, bayes => 1, is => 1, but => 1, not => 1, too => 1 }, "Stats updated after train()");

$nb->train("bad", "bad doggie!");
@labels = $nb->_labels;
ok(@labels == 2, "Second label created after 'bad' training");

