use strict;
use warnings;
use Test::More tests => 4;

use Redis::NaiveBayes;


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
