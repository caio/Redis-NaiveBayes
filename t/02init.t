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


my $ns  = 'test:';
my $tok = sub {};
my $nb  = Redis::NaiveBayes->new(
    namespace => $ns,
    tokenizer => $tok,
);

ok($nb, "Basic instantiation");
ok($nb->{namespace} eq $ns, "Namespace setting");
ok($nb->{tokenizer} == $tok, "Tokenizer setting");
ok(ref $nb->{redis} eq 'Redis', 'Local redis by default');
