use strict;
use warnings;
use Test::More tests => 1;

use Redis;
use Redis::NaiveBayes;


my $ns    = 'test:';
my $tok   = sub {};
my $redis = Redis->new;
my $nb  = Redis::NaiveBayes->new(
    redis     => $redis,
    namespace => $ns,
    tokenizer => $tok,
);

ok($nb->{redis} == $redis, 'Reuse existing redis instance');
