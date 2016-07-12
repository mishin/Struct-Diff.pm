package Struct::Diff;

use 5.006;
use strict;
use warnings FATAL => 'all';
use parent qw(Exporter);
use Carp qw(croak);

our @EXPORT_OK = qw(diff dselect dsplit dtraverse patch);

sub _validate_meta($) {
    my $d = shift;
    croak "Unsupported diff struct passed" if (ref $d ne 'HASH');
    if (exists $d->{'D'}) {
        croak "Value for 'D' status must be hash or array"
            unless (ref $d->{'D'} eq 'HASH' or ref $d->{'D'} eq 'ARRAY');
    }
    return 1;
}

=head1 NAME

Struct::Diff - Recursive diff tools for nested perl structures

=head1 VERSION

Version 0.61

=cut

our $VERSION = '0.61';

=head1 SYNOPSIS

    use Struct::Diff qw(diff dselect dsplit patch);

    $a = {x => [7,{y => 4}]};
    $b = {x => [7,{y => 9}],z => 33};

    $diff = diff($a, $b, noO => 1, noU => 1);       # omit unchanged and old values for changed items
    # $diff == {D => {x => {D => [{I => 1,N => {y => 9}}]},z => {A => 33}}};

    @items = dselect($diff, fromD => ['z']);        # get status for a particular key
    # @items == ({z => {A => 33}});

    $href = dsplit($diff);                          # divide diff
    # $dsplit->{a} not exists                       # unchanged omitted, other items originated from $b
    # $dsplit->{b} == {x => [{y => 9}],z => 33};

    patch($a, $diff);
    # $a now equal to $b by structure and data

=head1 EXPORT

Nothing exports by default

=head1 SUBROUTINES

=head2 diff

Returns HASH reference to recursive diff between two passed things. Beware when
changing diff: some of it's substructures are links to original structures.

    $diff = diff($a, $b, %opts);
    $patch = diff($a, $b, noU => 1, noO => 1, trimR => '1'); # smallest possible diff

=head3 Metadata format

Diff's keys shows status of each item in passed structures.

=over 4

=item A

Stands for 'added' (exists only in second structure), it's value - added item.

=item D

Means 'different' and contains subdiff.

=item I

Shows index for changed item (arrays only).

=item N

Is a new value for changed item.

=item O

Alike 'N', 'O' is a changed item's old value.

=item R

Similar for 'A', but for removed items.

=item U

Represent 'unchanged' items - common for both structures.

=back

=head3 Available options

=over 4

=item noX

Where X is a status (A, N, O, R, U); such status will be omitted.

=item trimR

Drop removed item's data.

=back

=cut

sub diff($$;@);
sub diff($$;@) {
    my ($a, $b, %opts) = @_;
    my $d = {};
    my $hidden;

    if (ref $a ne ref $b) {
        if ($opts{'noO'}) {
            $hidden = 1;
        } else {
            $d->{'O'} = $a;
        }
        if ($opts{'noN'}) {
            $hidden = 1;
        } else {
            $d->{'N'} = $b;
        }
    } elsif ((ref $a eq 'ARRAY') and ($a ne $b)) {
        for (my $i = 0; $i < @{$a} and $i < @{$b}; $i++) {
            my $tmp = diff($a->[$i], $b->[$i], %opts);
            if (keys %{$tmp}) {
                $tmp->{'I'} = $i if ($hidden);
                push @{$d->{'D'}}, $tmp;
            } else {
                $hidden = 1;
            }
        }
        if (@{$a} > @{$b}) {
            if ($opts{'noR'}) {
                $hidden = 1;
            } else {
                map { push @{$d->{'D'}}, { 'R' => $opts{'trimR'} ? undef : $_ } } @{$a}[@{$b}..$#{$a}];
            }
        }
        if (@{$a} < @{$b}) {
            if ($opts{'noA'}) {
                $hidden = 1;
            } else {
                map { push @{$d->{'D'}}, { 'A' => $_ } } @{$b}[@{$a}..$#{$b}];
            }
        }

        my $s = { map { $_, 1 } map { keys %{$_} } exists $d->{'D'} ? @{$d->{'D'}} : { 'U' => 1 } };
        delete $s->{'I'}; # ignored -- not a status

        if (keys %{$s} == 1 and not ($hidden or exists $s->{'D'})) { # all has same status - drop D and return as is
            my $n = (keys(%{$s}))[0];
            map { $_ = $_->{$n} } @{$d->{'D'}};
            $d->{$n} = delete $d->{'D'};
        }
    } elsif ((ref $a eq 'HASH') and ($a ne $b)) {
        for my $key (keys %{{ %{$a}, %{$b} }}) { # go througth united uniq keys
            if (exists $a->{$key} and exists $b->{$key}) {
                my $tmp = diff($a->{$key}, $b->{$key}, %opts);
                $hidden = 1 unless (keys %{$tmp});
                while (my ($s, $v) = each(%{$tmp})) {
                    if ($s eq 'D') {
                        $d->{'D'}->{$key} = $tmp;
                    } else {
                        $d->{$s}->{$key} = $v;
                    }
                }
            } elsif (exists $a->{$key}) {
                if ($opts{'noR'}) {
                    $hidden = 1;
                } else {
                    $d->{'R'}->{$key} = $opts{'trimR'} ? undef : $a->{$key};
                }
            } else {
                if ($opts{'noA'}) {
                    $hidden = 1;
                } else {
                    $d->{'A'}->{$key} = $b->{$key};
                }
            }
        }
        if (keys %{$d} > 1 or $hidden) {
            for my $s (keys %{$d}) {
                next if ($s eq 'D');
                map { $d->{'D'}->{$_}->{$s} = delete $d->{$s}->{$_} } keys %{$d->{$s}};
                delete $d->{$s};
            }
        }
    } else { # treat others as scalars
        unless ((not defined $a and not defined $b) or ((defined $a and defined $b) and ($a eq $b))) {
            $d->{'O'} = $a unless ($opts{'noO'});
            $d->{'N'} = $b unless ($opts{'noN'});
        }
    }
    $d->{'U'} = $a unless ($hidden or $opts{'noU'} or keys %{$d});

    return $d;
}

=head2 dselect

Returns items with desired status from diff's first level

    @added = dselect($diff, states => { 'A' => 1 } # something added?
    @items = dselect($diff, states => { 'A' => 1, 'U' => 1 }, 'fromD' => [ 'a', 'b', 'c' ]) # from D hash
    @items = dselect($diff, states => { 'D' => 1, 'N' => 1 }, 'fromD' => [ 0, 1, 3, 5, 9 ]) # from D array

=head3 Available options

=over 4

=item fromD

Select items from diff's 'D'. Expects list of positions (indexes for arrays and keys for hashes). All items with
specified states will be returned if opt exists, but not defined or is an empty list.

=item states

Expects hash with desired states as keys with values in some true value. Items with all states will be returned if
opt not defined.

=back

=cut

sub dselect(@) {
    my ($d, %opts) = @_;
    _validate_meta($d);
    my @out;

    if (exists $opts{'fromD'}) {
        croak "'fromD' defined, but no 'D' state found" unless (exists $d->{'D'});
        if (ref $d->{'D'} eq 'ARRAY') {
            for my $i (($opts{'fromD'} and @{$opts{'fromD'}}) ? @{$opts{'fromD'}} : 0..$#{$d->{'D'}}) {
                croak "Requested index $i not in diff's array range" unless ($i >= 0 and $i < @{$d->{'D'}});
                push @out, {
                    map { $_ => $d->{'D'}->[$i]->{$_} }
                    grep { not $opts{'states'} or exists $opts{'states'}->{$_} }
                    keys %{$d->{'D'}->[$i]}
                };
            }
        } else { # HASH
            for my $k (($opts{'fromD'} and @{$opts{'fromD'}}) ? @{$opts{'fromD'}} : keys %{$d->{'D'}}) {
                push @out, {
                    map { $k => { $_ => $d->{'D'}->{$k}->{$_} } }
                    grep { not $opts{'states'} or exists $opts{'states'}->{$_} }
                    keys %{$d->{'D'}->{$k}}
                };
            }
        }
    } else {
        @out = { map { $_ => $d->{$_} } grep { not $opts{'states'} or exists $opts{'states'}->{$_} } keys %{$d} };
    }

    return grep { keys %{$_} } @out;
}

=head2 dsplit

Divide diff to pseudo original structures

    $structs = dsplit($diff);
    # $structs->{'a'} - now contains items originated from $a
    # $structs->{'b'} - same for $b

=cut

sub dsplit($);
sub dsplit($) {
    my $d = shift;
    _validate_meta($d);
    my $s = {};

    if (exists $d->{'D'}) {
        if (ref $d->{'D'} eq 'ARRAY') {
            for my $di (@{$d->{'D'}}) {
                my $ts = dsplit($di);
                push @{$s->{'a'}}, $ts->{'a'} if (exists $ts->{'a'});
                push @{$s->{'b'}}, $ts->{'b'} if (exists $ts->{'b'});
            }
        } else { # HASH
            for my $key (keys %{$d->{'D'}}) {
                my $ts = dsplit($d->{'D'}->{$key});
                $s->{'a'}->{$key} = $ts->{'a'} if (exists $ts->{'a'});
                $s->{'b'}->{$key} = $ts->{'b'} if (exists $ts->{'b'});
            }
        }
    } elsif (exists $d->{'U'}) {
        $s->{'a'} = $s->{'b'} = $d->{'U'};
    } elsif (exists $d->{'A'}) {
        $s->{'b'} = $d->{'A'};
    } elsif (exists $d->{'R'}) {
        $s->{'a'} = $d->{'R'};
    } else {
        $s->{'b'} = $d->{'N'} if (exists $d->{'N'});
        $s->{'a'} = $d->{'O'} if (exists $d->{'O'});
    }

    return $s;
}

=head2 dtraverse

Traverse through diff invoking callback functions for subdiff statuses. Important: path (secont argument,
passed to callback functions) is actual for callback lifetime and will be changed afterwards.

    my $opts = {
        A => sub { print "added:", $_[0], "depth:", @{$_[1]} },
        U => sub { print "unchaanged: ", $_[0] },
    };
    dtraverse($diff, $opts);

=cut

sub dtraverse($$;$);
sub dtraverse($$;$) {
    my ($d, $o, $p) = (shift, shift, shift || []);
    _validate_meta($d);

    if (exists $d->{'D'}) {
        if (ref $d->{'D'} eq 'ARRAY') {
            for (my $i = 0; $i < @{$d->{'D'}}; $i++) {
                push @{$p}, [$i];
                dtraverse($d->{'D'}->[$i], $o, $p);
                pop @{$p};
            }
        } else { # HASH
            for my $k (keys %{$d->{'D'}}) {
                push @{$p}, { 'keys' => [$k] };
                dtraverse($d->{'D'}->{$k}, $o, $p);
                pop @{$p};
            }
        }
    } elsif (exists $d->{'U'} and $o->{'U'}) {
        $o->{'U'}($d->{'U'}, $p);
    } elsif (exists $d->{'A'} and $o->{'A'}) {
        $o->{'A'}($d->{'A'}, $p);
    } elsif (exists $d->{'R'} and $o->{'R'}) {
        $o->{'R'}($d->{'R'}, $p);
    } else {
        $o->{'N'}($d->{'N'}, $p) if (exists $d->{'N'} and $o->{'N'});
        $o->{'O'}($d->{'O'}, $p) if (exists $d->{'O'} and $o->{'O'});
    }
}

=head2 patch

Apply diff

    patch($a, $diff);

=cut

sub patch($$);
sub patch($$) {
    my ($s, $d) = @_;
    _validate_meta($d);

    if (exists $d->{'D'}) {
        if (ref $d->{'D'} eq 'ARRAY') {
            for my $i (0..$#{$d->{'D'}}) {
                my $si = exists $d->{'D'}->[$i]->{'I'} ? $d->{'D'}->[$i]->{'I'} : $i; # use provided index
                if (exists $d->{'D'}->[$i]->{'D'} or exists $d->{'D'}->[$i]->{'N'}) {
                    patch(ref $s->[$si] ? $s->[$si] : \$s->[$si], $d->{'D'}->[$i]);
                } elsif (exists $d->{'D'}->[$i]->{'A'}) {
                    push @{$s}, $d->{'D'}->[$i]->{'A'};
                } elsif (exists $d->{'D'}->[$i]->{'R'}) {
                    pop @{$s};
                }
            }
        } else { # HASH
            for my $k (keys %{$d->{'D'}}) {
                if (exists $d->{'D'}->{$k}->{'D'} or exists $d->{'D'}->{$k}->{'N'}) {
                    patch(ref $s->{$k} ? $s->{$k} : \$s->{$k}, $d->{'D'}->{$k});
                } elsif (exists $d->{'D'}->{$k}->{'A'}) {
                    $s->{$k} = $d->{'D'}->{$k}->{'A'};
                } elsif (exists $d->{'D'}->{$k}->{'R'}) {
                    delete $s->{$k};
                }
            }
        }
    } elsif (exists $d->{'N'}) {
        ${$s} = $d->{'N'};
    }

    return 1;
}

=head1 LIMITATIONS

Struct::Diff fails on structures with loops in references. has_circular_ref from Data::Structure::Util can help
to detect such structures.

Only scalars, refs to scalars, ref to arrays and ref to hashes correctly traversed. All other data types compared
by their references.

No object oriented interface provided.

=head1 AUTHOR

Michael Samoglyadov, C<< <mixas at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-struct-diff at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Struct-Diff>. I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Struct::Diff

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Struct-Diff>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Struct-Diff>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Struct-Diff>

=item * Search CPAN

L<http://search.cpan.org/dist/Struct-Diff/>

=back

=head1 SEE ALSO

L<Data::Diff>, L<Data::Difference>, L<Data::Deep>

L<Array::Diff>, L<Array::Compare>, L<Algorithm::Diff>, L<Data::Compare>, L<Hash::Diff>, L<Test::Struct>,
L<Struct::Compare>

L<Data::Structure::Util>, L<Struct::Path>, L<Struct::Path::PerlStyle>

=head1 LICENSE AND COPYRIGHT

Copyright 2015-2016 Michael Samoglyadov.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

1; # End of Struct::Diff
