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

plan tests => 2;

my $ns    = 'test:';
my $tok   = sub {};
my $redis = Redis->new;
my $nb  = Redis::NaiveBayes->new(
    redis     => $redis,
    namespace => $ns,
    tokenizer => $tok,
);

#FIXME Use a mock lib instead of a real redis here

$nb->_exec('sadd', '_exec', 'hello world');
my @set = $redis->smembers('test:_exec');

ok(grep { $_ eq 'hello world' } @set, "sadd via _exec, smembers via Redis");

$redis->hset('test:hash', '_exec', 42);
my $answer = $nb->_exec('hget', 'hash', '_exec');

ok($answer == 42, "hset via Redis, hget via _exec");
