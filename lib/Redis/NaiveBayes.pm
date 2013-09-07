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

my $LUA_SCORES = q{
    -- KEYS
    --   1-N: all possible labels
    -- ARGV
    --   1: correction
    --   2: number of tokens
    --   3-X: tokens
    --   X+1-N: values for each token
    -- FIXME: Maybe I shouldn't care about redis-cluster?
    -- FIXME: I'm ignoring the scores per token on purpose for now

    local scores = {}
    local correction = ARGV[1]
    local num_tokens = ARGV[2]

    for index, label in ipairs(KEYS) do
        local tally = 0
        for _, value in ipairs(redis.call('hvals', label)) do
            tally = tally + value
        end

        if tally > 0 then
            scores[label] = 0.0

            for idx, token in ipairs(ARGV) do
                if idx > num_tokens + 2 then
                    break
                end

                if idx > 2 then
                    local score = redis.call('hget', label, token);

                    if (not score or score == 0) then
                        score = correction
                    end

                    scores[label] = scores[label] + math.log(score / tally)
                end
            end
        end
    end

    -- this is so fucking retarded. I now regret this luascript branch idea
    local return_crap = {};
    local index = 1
    for _, label in ipairs(KEYS) do
        if scores[label] then
            return_crap[index] = label
            return_crap[index+1] = scores[label]
        end
        index = index + 2
    end

    return return_crap;
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
    ($self->{scripts}->{scores}) = $self->{redis}->script_load($LUA_SCORES);
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

sub _mrproper {
    my ($self) = @_;

    my @keys = $self->{redis}->keys($self->{namespace} . '*');
    $self->{redis}->del(@keys) if @keys;
}

sub _train {
    my ($self, $label, $item, $script) = @_;

    my @keys = ($self->{namespace} . LABELS, $self->{namespace} . $label);
    my @argv = ($label);

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    push @argv, (scalar keys %$occurrences), keys %$occurrences, values %$occurrences;

    $self->_run_script($script, scalar @keys, @keys, @argv);

    return $occurrences;
}

sub train {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'train');
}

sub untrain {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'untrain');
}

sub scores {
    my ($self, $item) = @_;

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    my @labels = map { $self->{namespace} . $_ } ($self->_labels);
    my @argv = ($self->{correction}, scalar keys %$occurrences, keys %$occurrences, values %$occurrences);

    my %scores = $self->_run_script('scores', scalar @labels, @labels, @argv);

    return { map { substr($_, length($self->{namespace})) => $scores{$_} } keys %scores };
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
