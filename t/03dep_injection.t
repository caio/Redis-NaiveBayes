use strict;
use warnings;
use Test::More;

use Redis;
use Redis::NaiveBayes;

eval {
    Redis->new;
    1;
} or do {
    plan skip_all => "No Redis instance running";
};

plan tests => 1;


my $ns    = 'test:';
my $tok   = sub {};
my $redis = Redis->new;
my $nb  = Redis::NaiveBayes->new(
    redis     => $redis,
    namespace => $ns,
    tokenizer => $tok,
);

ok($nb->{redis} == $redis, 'Reuse existing redis instance');
