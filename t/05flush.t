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

plan tests => 16;

my $ns    = 'test:';
my $tok   = sub {};
my $redis = Redis->new;
my $nb  = Redis::NaiveBayes->new(
    redis     => $redis,
    namespace => $ns,
    tokenizer => $tok,
);

my @test = qw(all your base are belong to us);

# Manually add stuff to the redis store so that the namespace is dirty
$nb->_exec('sadd', Redis::NaiveBayes::LABELS, $_) for @test;
$nb->_exec('hincrby', $_, 'shrubery', int(rand)) for @test;

my @labels = $nb->_labels;
ok(@labels > 0, "Labels set is dirty");

foreach my $label (@test) {
    my $priors = $nb->_priors('base');
    ok(%$priors, "Priors hash for '$label' is dirty");
}

$nb->flush;

@labels = $nb->_labels;
ok(@labels == 0, "Labels set is empty now");

foreach my $label (@test) {
    my $priors = $nb->_priors('base');
    ok(! %$priors, "Priors hash for '$label' is empty");
}

