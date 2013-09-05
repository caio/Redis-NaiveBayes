package Redis::NaiveBayes;
# ABSTRACT: A performance-freak Redis-backed NaiveBayes implementation

use strict;
use warnings;
use List::Util qw(sum);

use Redis;

use constant {
    DEBUG => 0,
    LABELS => 'labels',
};


sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;

    $self->{redis}      = $args{redis}      || Redis->new(%args);
    $self->{correction} = $args{correction} || 0.001;
    $self->{namespace}  = $args{namespace}  or die "Missing namespace";
    $self->{tokenizer}  = $args{tokenizer}  or die "Missing tokenizer";

    return $self;
}

sub _exec {
    my ($self, $command, $key, @rest) = @_;

    DEBUG and $self->_debug("Will execute command '%s' on '%s'", ($command, $self->{namespace} . $key));
    return $self->{redis}->$command($self->{namespace} . $key, @rest);
}

sub _debug {
    my $self = shift;
    printf STDERR @_;
}

sub flush {
    my ($self) = @_;

    for my $label ($self->_labels) {
        $self->_exec('del', $label);
    }
    $self->_exec('del', 'labels');
}

sub train {
    my ($self, $label, $item) = @_;

    DEBUG and $self->_debug("Training as '%s' the following: '%s'", $label, $item);

    $self->_exec('sadd', LABELS, $label);

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    for my $token (keys %$occurrences) {
        my $score = $occurrences->{$token};

        $self->_exec('hincrby', $label, $token, $score);
    }

    return $occurrences;
}

# FIXME there are some obvious race conditions here if we're not using pipielines
sub untrain {
    my ($self, $label, $item) = @_;

    DEBUG and $self->_debug("UNtraining as '%s' the following: '%s'", $label, $item);

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    for my $token (keys %$occurrences) {
        # Do nothing when we have no data for $token
        my $current = $self->_exec('hget', $label, $token);
        return unless $current;

        my $score = $occurrences->{$token};

        if ($current - $score > 0) {
            $self->_exec('hincrby', $label, $token, -1 * $score);
        }
        else {
            $self->_exec('hdel', $label, $token);
        }
    }

    # Delete label hash if its total score is zero/negative
    my $total = sum($self->_exec('hvals', $label));
    if (! $total or $total < 0) {
        $self->_exec('del', $label);
        $self->_exec('srem', LABELS, $label);
    }

    return $occurrences;
}

sub _labels {
    my ($self) = @_;

    return $self->_exec('smembers', LABELS);
}

sub _priors {
    my ($self, $label) = @_;

    my %data = $self->_exec('hgetall', $label);
    return { %data };
}


1;

__END__

=encoding utf8
