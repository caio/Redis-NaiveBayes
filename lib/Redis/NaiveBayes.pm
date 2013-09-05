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

# Lua scripts
my $LUA_FLUSH = q{
    -- KEYS:
    --   1: LABELS set
    --   2-N: LABELS set contents

    -- Delete all label stat hashes
    for index, label in ipairs(KEYS) do
        if index > 1 then
            redis.call('del', label)
        end
    end

    -- Delete the LABELS set
    redis.call('del', KEYS[1]);
};

my $LUA_TRAIN = q{
    -- KEYS:
    --   1: LABELS set
    --   2: label being updated
    -- ARGV:
    --   1: raw label name being trained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    redis.call('sadd', KEYS[1], ARGV[1])

    local label      = KEYS[2]
    local num_tokens = ARGV[2]

    for index, token in ipairs(ARGV) do
        if index > num_tokens + 2 then
            break
        end
        if index > 2 then
            redis.call('hincrby', label, token, ARGV[index + num_tokens])
        end
    end
};

my $LUA_UNTRAIN = q{
    -- KEYS:
    --   1: LABELS set
    --   2: label being updated
    -- ARGV:
    --   1: raw label name being untrained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    local label      = KEYS[2]
    local num_tokens = ARGV[2]

    for index, token in ipairs(ARGV) do
        if index > num_tokens + 2 then
            break
        end
        if index > 2 then
            local current = redis.call('hget', label, token);

            if (current and current - ARGV[index + num_tokens] > 0) then
                redis.call('hincrby', label, token, -1 * ARGV[index + num_tokens])
            else
                redis.call('hdel', label, token)
            end
        end
    end

    local total = 0
    for index, value in ipairs(redis.call('hvals', label)) do
        total = total + value
    end

    if total <= 0 then
        redis.call('del', label)
        redis.call('srem', KEYS[1], ARGV[1])
    end
};


sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;

    $self->{redis}      = $args{redis}      || Redis->new(%args);
    $self->{correction} = $args{correction} || 0.001;
    $self->{namespace}  = $args{namespace}  or die "Missing namespace";
    $self->{tokenizer}  = $args{tokenizer}  or die "Missing tokenizer";

    $self->_load_scripts;

    return $self;
}

sub _load_scripts {
    my ($self) = @_;

    $self->{scripts} = {};

    ($self->{scripts}->{flush}) = $self->{redis}->script_load($LUA_FLUSH);
    ($self->{scripts}->{train}) = $self->{redis}->script_load($LUA_TRAIN);
    ($self->{scripts}->{untrain}) = $self->{redis}->script_load($LUA_UNTRAIN);
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

sub _run_script {
    my ($self, $script, $numkeys, @rest) = @_;

    my $sha1 = $self->{scripts}->{$script} or die "Script wasn't loaded: '$script'";

    $self->{redis}->evalsha($sha1, $numkeys, @rest);
}

sub flush {
    my ($self) = @_;

    my @keys = (LABELS);
    push @keys, ($self->_labels);
    $self->_run_script('flush', scalar @keys, map { $self->{namespace} . $_ } @keys);
}

sub train {
    my ($self, $label, $item) = @_;

    DEBUG and $self->_debug("Training as '%s' the following: '%s'", $label, $item);

    my @keys = ($self->{namespace} . LABELS, $self->{namespace} . $label);
    my @argv = ($label);

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    push @argv, (scalar keys %$occurrences), keys %$occurrences, values %$occurrences;

    $self->_run_script('train', scalar @keys, @keys, @argv);

    return $occurrences;
}

sub untrain {
    my ($self, $label, $item) = @_;

    DEBUG and $self->_debug("UNtraining as '%s' the following: '%s'", $label, $item);

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    my @keys = ($self->{namespace} . LABELS, $self->{namespace} . $label);
    my @argv = ($label);

    push @argv, (scalar keys %$occurrences), keys %$occurrences, values %$occurrences;

    $self->_run_script('untrain', scalar @keys, @keys, @argv);

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
