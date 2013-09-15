package Redis::NaiveBayes;
# ABSTRACT: A generic Redis-backed NaiveBayes implementation

=head1 SYNOPSIS

    my $tokenizer = sub {
        my $input = shift;

        my %occurs;
        $occurs{$_}++ for split(/\s/, lc $input);

        return \%occurs;
    };

    my $bayes = Redis::NaiveBayes->new(
        namespace => 'playground:',
        tokenizer => \&tokenizer,
    );

=head1 DESCRIPTION

This distribution provides a very simple NaiveBayes classifier
backed by a Redis instance. It uses the evalsha functionality
available since Redis 2.6.0 to try to speed things up while
avoiding some obvious race conditions during the untrain() phase.

The goal of Redis::NaiveBayes is to keep dependencies at
minimum while being as generic as possible to allow any sort
of usage. By design, it doesn't provide any sort of tokenization
nor filtering out of the box.

=head1 NOTES

This module is heavilly inspired by the Python implementation
available at https://github.com/jart/redisbayes - the main
difference, besides the obvious

=head1 SEE ALSO

L<Redis>, L<Redis::Bayes>, L<Algorithm::NaiveBayes>

=cut

use strict;
use warnings;
use List::Util qw(sum reduce);

use Redis;

use constant {
    DEBUG => 0,
    LABELS => 'labels',
};

# Lua scripts
my $LUA_FLUSH_FMT = q{
    local namespace  = '%s'
    local labels_key = namespace .. '%s'
    for _, member in ipairs(redis.call('smembers', labels_key)) do
        redis.call('del', namespace .. member)
    end
    redis.call('del', labels_key);
};

my $LUA_TRAIN_FMT = q{
    -- ARGV:
    --   1: raw label name being trained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    local namespace  = '%s'
    local labels_key = namespace .. '%s'
    local label      = namespace .. ARGV[1]
    local num_tokens = ARGV[2]

    redis.call('sadd', labels_key, ARGV[1])

    for index, token in ipairs(ARGV) do
        if index > num_tokens + 2 then
            break
        end
        if index > 2 then
            redis.call('hincrby', label, token, ARGV[index + num_tokens])
        end
    end
};

my $LUA_UNTRAIN_FMT = q{
    -- ARGV:
    --   1: raw label name being untrained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    local namespace  = '%s'
    local labels_key = namespace .. '%s'
    local label      = namespace .. ARGV[1]
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
    for _, value in ipairs(redis.call('hvals', label)) do
        total = total + value
    end

    if total <= 0 then
        redis.call('del', label)
        redis.call('srem', labels_key, ARGV[1])
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
    for key, value in pairs(scores) do
        return_crap[index] = key
        return_crap[index+1] = value
        index = index + 2
    end

    return return_crap;
};

=method new

    my $bayes = Redis::NaiveBayes->new(
        namespace  => 'playground:',
        tokenizer  => \&tokenizer,
        correction => 0.1,
        redis      => $redis_instance,
    );

Instantiates a L<Redis::NaiveBayes> instance using the provided
C<correction>, C<namespace> and C<tokenizers>.

If provided, it also uses a L<Redis> instance (C<redis> parameter)
instead of instantiating one by itself.

A tokenizer is any subroutine that returns a HASHREF of occurrences
in the item provided for train()ining or classify()ing.

=cut

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

sub _redis_script_load {
    my ($self, $script_fmt, @args) = @_;

    my ($sha1) = $self->{redis}->script_load(sprintf($script_fmt, @args));

    return $sha1;
}

sub _load_scripts {
    my ($self) = @_;

    $self->{scripts} = {};

    $self->{scripts}->{flush} = $self->_redis_script_load($LUA_FLUSH_FMT, ($self->{namespace}, LABELS));
    $self->{scripts}->{train} = $self->_redis_script_load($LUA_TRAIN_FMT, ($self->{namespace}, LABELS));
    $self->{scripts}->{untrain} = $self->_redis_script_load($LUA_UNTRAIN_FMT, ($self->{namespace}, LABELS));
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

    $numkeys ||= 0;
    my $sha1 = $self->{scripts}->{$script} or die "Script wasn't loaded: '$script'";

    $self->{redis}->evalsha($sha1, $numkeys, @rest);
}

=method flush

    $bayes->flush;

Cleanup all the possible keys this classifier instance could've
touched. If you want to clean everything under the provided namespace,
call _mrproper() instead, but beware that it will delete all the
keys that match C<namespace*>.

=cut

sub flush {
    my ($self) = @_;

    $self->_run_script('flush');
}

sub _mrproper {
    my ($self) = @_;

    my @keys = $self->{redis}->keys($self->{namespace} . '*');
    $self->{redis}->del(@keys) if @keys;
}

sub _train {
    my ($self, $label, $item, $script) = @_;

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    my @argv = ($label, (scalar keys %$occurrences), keys %$occurrences, values %$occurrences);

    $self->_run_script($script, 0, @argv);

    return $occurrences;
}

=method train

    $bayes->train("ham", "this is a good message");
    $bayes->train("spam", "price from Nigeria needs your help");

Trains as a label ("ham") the given item. The item can be any arbitrary
structure as long as the provided C<tokenizer> understands it.

=cut

sub train {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'train');
}

=method untrain

    $bayes->untrain("ham", "I don't thing this message is good anymore")

The opposite of train().

=cut

sub untrain {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'untrain');
}

=method classify

    my $label = $bayes->classify("Nigeria needs help");
    >>> "spam"

Gets the most probable category the provided item in is.

=cut

sub classify {
    my ($self, $item) = @_;

    my $scores = $self->scores($item);

    my $best_label = reduce { $scores->{$a} > $scores->{$b} ? $a : $b } keys %$scores;

    return $best_label;
}

=method scores

    my $scores = $bayes->scores("any sort of message");

Returns a HASHREF with the scores for each of the labels known by the model

=cut

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
