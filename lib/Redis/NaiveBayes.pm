package Redis::NaiveBayes;
# ABSTRACT: A performance-freak Redis-backed NaiveBayes implementation

use strict;
use warnings;


sub new {
    my ($class) = @_;

    my $self = {};
    bless $self, $class;
}


1;

__END__

=encoding utf8
