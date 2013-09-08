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

plan tests => 4;

sub tokenizer {
    my $input = shift;
    my @it = split(/\s/, lc $input);

    my %toks;
    $toks{$_}++ for @it;

    delete $toks{$_} for qw/the i and/;

    return \%toks;
}

my $nb = Redis::NaiveBayes->new(
    namespace => 'test:',
    tokenizer => \&tokenizer,
    correction => 0.1,
);

# Start from a blank state
$nb->flush;

ok(! $nb->classify("nothing trained yet"), "undef when unable to assess");

$nb->train('good', 'sunshine drugs love sex lobster sloth');
$nb->train('bad', 'fear death horror government zombie god');

is($nb->classify('sloths are so cute i love them'), 'good', "classified correctly as good");
is($nb->classify('i fear god and love the government'), 'bad', "classified correctly as bad");

my $scores = $nb->scores('i fear god and love the government');
is_deeply($scores, { bad => -9, good => -14 }, "scored as expected");
