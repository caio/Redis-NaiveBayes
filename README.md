# NAME

Redis::NaiveBayes - A generic Redis-backed NaiveBayes implementation

# VERSION

version 0.0.1

# SYNOPSIS

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

# DESCRIPTION

This distribution provides a very simple NaiveBayes classifier
backed by a Redis instance. It uses the evalsha functionality
available since Redis 2.6.0 to try to speed things up while
avoiding some obvious race conditions during the untrain() phase.

The goal of Redis::NaiveBayes is to keep dependencies at
minimum while being as generic as possible to allow any sort
of usage. By design, it doesn't provide any sort of tokenization
nor filtering out of the box.

# METHODS

## new

    my $bayes = Redis::NaiveBayes->new(
        namespace  => 'playground:',
        tokenizer  => \&tokenizer,
        correction => 0.1,
        redis      => $redis_instance,
    );

Instantiates a [Redis::NaiveBayes](http://search.cpan.org/perldoc?Redis::NaiveBayes) instance using the provided
`correction`, `namespace` and `tokenizers`.

If provided, it also uses a [Redis](http://search.cpan.org/perldoc?Redis) instance (`redis` parameter)
instead of instantiating one by itself.

A tokenizer is any subroutine that returns a HASHREF of occurrences
in the item provided for train()ining or classify()ing.

## flush

    $bayes->flush;

Cleanup all the possible keys this classifier instance could've
touched. If you want to clean everything under the provided namespace,
call \_mrproper() instead, but beware that it will delete all the
keys that match `namespace*`.

## train

    $bayes->train("ham", "this is a good message");
    $bayes->train("spam", "price from Nigeria needs your help");

Trains as a label ("ham") the given item. The item can be any arbitrary
structure as long as the provided `tokenizer` understands it.

## untrain

    $bayes->untrain("ham", "I don't thing this message is good anymore")

The opposite of train().

## classify

    my $label = $bayes->classify("Nigeria needs help");
    >>> "spam"

Gets the most probable category the provided item in is.

## scores

    my $scores = $bayes->scores("any sort of message");

Returns a HASHREF with the scores for each of the labels known by the model

# NOTES

This module is heavilly inspired by the Python implementation
available at https://github.com/jart/redisbayes - the main
difference, besides the obvious language choice, is that
Redis::NaiveBayes focuses on being generic and minimizing
the number of roundtrips to Redis.

# TODO

- Add support for additive smoothing

# SEE ALSO

[Redis](http://search.cpan.org/perldoc?Redis), [Redis::Bayes](http://search.cpan.org/perldoc?Redis::Bayes), [Algorithm::NaiveBayes](http://search.cpan.org/perldoc?Algorithm::NaiveBayes)

# AUTHOR

Caio Romão <cpan@caioromao.com>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by Caio Romão.

This is free software, licensed under:

    The MIT (X11) License
