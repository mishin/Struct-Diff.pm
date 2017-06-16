package Struct::Diff;

use 5.006;
use strict;
use warnings FATAL => 'all';
use parent qw(Exporter);
use Carp qw(croak);
use Storable qw(freeze);
use Algorithm::Diff qw(sdiff);

our @EXPORT_OK = qw(
    diff
    list_diff
    dsplit
    dtraverse
    patch
);

sub _validate_meta($) {
    croak "Unsupported diff struct passed" if (ref $_[0] ne 'HASH');
    if (exists $_[0]->{'D'}) {
        croak "Value for 'D' status must be hash or array"
            unless (ref $_[0]->{'D'} eq 'HASH' or ref $_[0]->{'D'} eq 'ARRAY');
    }
}

=head1 NAME

Struct::Diff - Recursive diff tools for nested perl structures

=head1 VERSION

Version 0.87

=cut

our $VERSION = '0.87';

=head1 SYNOPSIS

    use Struct::Diff qw(diff dsplit list_diff patch);

    $a = {x => [7,{y => 4}]};
    $b = {x => [7,{y => 9}],z => 33};

    $diff = diff($a, $b, noO => 1, noU => 1); # omit unchanged items and old values
    # $diff == {D => {x => {D => [{I => 1,N => {y => 9}}]},z => {A => 33}}}

    $splitted = dsplit($diff);
    # $splitted->{a} # not exists
    # $splitted->{b} == {x => [{y => 9}],z => 33}

    @list_diff = list_diff($diff); # list (path and ref pairs) all diff entries
    # $list_diff == [[{keys => ['z']}],\{A => 33},[{keys => ['x']},[0]],\{I => 1,N => {y => 9}}]

    patch($a, $diff); # $a now equal to $b by structure and data

=head1 EXPORT

Nothing is exported by default.

=head1 DIFF METADATA FORMAT

Diff is simply a HASH whose keys shows status for each item in passed structures.

=over 4

=item A

Stands for 'added' (exists only in second structure), it's value - added item.

=item D

Means 'different' and contains subdiff.

=item I

Index for changed array item.

=item N

Is a new value for changed item.

=item O

Alike C<N>, C<O> is a changed item's old value.

=item R

Similar for C<A>, but for removed items.

=item U

Represent unchanged items.

=back

=head1 SUBROUTINES

=head2 diff

Returns hashref to recursive diff between two passed things. Beware when
changing diff: some of it's substructures are links to original structures.

    $diff = diff($a, $b, %opts);
    $patch = diff($a, $b, noU => 1, noO => 1, trimR => 1); # smallest possible diff

=head3 Options

=over 4

=item noX

Where X is a status (C<A>, C<N>, C<O>, C<R>, C<U>); such status will be omitted.

=item trimR

Drop removed item's data.

=back

=cut

sub diff($$;@);
sub diff($$;@) {
    my ($a, $b, %opts) = @_;

    my $d = {};
    local $Storable::canonical = 1; # for equal snapshots for equal by data hashes

    if (ref $a ne ref $b) {
        $d->{O} = $a unless ($opts{noO});
        $d->{N} = $b unless ($opts{noN});
    } elsif (ref $a eq 'ARRAY') {
        return $opts{noU} ? {} : { U => $a } if ($a == $b);

        my @sd = sdiff($a, $b, sub { freeze \$_[0] });
        my ($s, $hidden);
        for my $i (0 .. $#sd) {
            my $item;
            if ($sd[$i]->[0] eq 'u') {
                $item->{U} = $sd[$i]->[1] unless ($opts{noU});
            } elsif ($sd[$i]->[0] eq 'c') {
                $item = diff($sd[$i]->[1], $sd[$i]->[2], %opts);
            } elsif ($sd[$i]->[0] eq '+') {
                $item->{A} = $sd[$i]->[2] unless ($opts{noA});
            } else { # '-'
                $item->{R} = $opts{trimR} ? undef : $sd[$i]->[1]
                    unless ($opts{noR});
            }

            if ($item) {
                map { $s->{$_} = 1 } keys %{$item};
                $item->{I} = $i if ($hidden);
                push @{$d->{D}}, $item;
            } else {
                $hidden = 1;
            }
        }

        if ((my @k = keys %{$s}) == 1 and not ($hidden or exists $s->{D})) { # all have same status - return it
            map { $_ = $_->{$k[0]} } @{$d->{D}};
            $d->{$k[0]} = delete $d->{D};
        }

        $d->{U} = $a unless ($hidden or keys %{$d});
    } elsif (ref $a eq 'HASH') {
        return $opts{noU} ? {} : { U => $a } if ($a == $b);

        my @keys = keys %{{ %{$a}, %{$b} }}; # united uniq keys
        return $opts{noU} ? {} : { U => {} } unless (@keys);

        my ($alt, $sd);
        for my $key (@keys) {
            if (exists $a->{$key} and exists $b->{$key}) {
                if (freeze(\$a->{$key}) eq freeze(\$b->{$key})) {
                    $d->{U}->{$key} = $alt->{D}->{$key}->{U} = $a->{$key}
                        unless ($opts{noU});
                } else {
                    $sd = diff($a->{$key}, $b->{$key}, %opts);
                    if (exists $sd->{D}) {
                        $d->{D}->{$key} = $alt->{D}->{$key} = $sd;
                    } else {
                        map { $d->{$_}->{$key} = $alt->{D}->{$key}->{$_} = $sd->{$_} } keys %{$sd};
                    }
                }
            } elsif (exists $a->{$key}) {
                $d->{R}->{$key} = $alt->{D}->{$key}->{R} =
                    $opts{trimR} ? undef : $a->{$key}
                        unless ($opts{noR});
            } else {
                $d->{A}->{$key} = $alt->{D}->{$key}->{A} = $b->{$key}
                    unless ($opts{noA});
            }
        }

        $d = $alt if (keys %{$d} > 1); # return 'D' version of diff
    } else {
        return $opts{noU} ? {} : { U => $a }
            if (ref $a ? $a == $b : freeze(\$a) eq freeze(\$b));
        $d->{O} = $a unless ($opts{noO});
        $d->{N} = $b unless ($opts{noN});
    }

    return $d;
}

=head2 list_diff

List pairs (path, ref_to_subdiff) for provided diff. See
L<Struct::Path/ADDRESSING SCHEME> for path format specification.

    @list = list_diff(diff($frst, $scnd);

=head3 Options

=over 4

=item depth E<lt>intE<gt>

Don't dive deeper than defined number of levels.

=item sort E<lt>sub|true|falseE<gt>

Defines how to traverse hash subdiffs. Keys will be picked randomely (C<keys>
behavior, default), sorted by provided subroutine (if value is a coderef) or
lexically sorted if set to some other true value.

=back

=cut

sub list_diff($;@) {
    my ($tmp, %opts) = @_;
    $opts{depth} = 0 unless ($opts{depth});

    my @stack = ([], \$tmp); # init: (path, diff)
    my ($diff, @list, $path);

    while (@stack) {
        ($path, $diff) = splice @stack, 0, 2;

        if (!exists ${$diff}->{D} or $opts{depth} and @{$path} >= $opts{depth}) {
            push @list, $path, $diff;
        } elsif (ref ${$diff}->{D} eq 'ARRAY') {
            map { unshift @stack, [@{$path}, [$_]], \${$diff}->{D}->[$_] }
                reverse 0 .. $#{${$diff}->{D}};
        } else { # HASH
            map { unshift @stack, [@{$path}, {keys => [$_]}], \${$diff}->{D}->{$_} }
                $opts{sort}
                    ? (ref $opts{sort} eq 'CODE'
                        ? reverse $opts{sort}(keys %{${$diff}->{D}})
                        : reverse sort keys %{${$diff}->{D}})
                    : keys %{${$diff}->{D}};
        }
    }

    return @list;
}

=head2 dsplit

Divide diff to pseudo original structures

    $structs = dsplit($diff);
    # $structs->{a} - contains items originated from $a
    # $structs->{b} - same for $b

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

Deprecated. L</list_diff> should be used instead.

Traverse through diff invoking callback function for subdiff statuses.

    my $opts = {
        callback => sub { print "added value:", $_[0], "depth:", @{$_[1]}, "status:", $_[2]; return 1},
        sortkeys => sub { sort { $a <=> $b } @_ }   # numeric sort for keys under diff
    };
    dtraverse($diff, $opts);

=head3 Options

=over 4

=item depth E<lt>intE<gt>

Don't dive deeper than defined number of levels

=item callback E<lt>subE<gt>

Mandatory option, must contain coderef to callback fuction. Four arguments will be passed to provided
subroutine: value, path, status and ref to subdiff. Function must return some true value on success. Important:
path (second argument) is actual for callback lifetime and will be immedeately changed afterwards.

=item sortkeys E<lt>subE<gt>

Defines how will be traversed subdiffs for hashes. Keys will be picked randomely (depends on C<keys> behavior,
default), sorted by provided subroutine (if value is a coderef) or lexically sorted if set to some other true value.

=item statuses E<lt>listE<gt>

Exact list of statuses. Sequence defines invocation priority.

=back

=cut

sub dtraverse($$;$);
sub dtraverse($$;$) {
    my ($d, $o, $p) = (shift, shift, shift || []);
    croak "Callback must be a code reference" unless (ref $o->{'callback'} eq 'CODE');
    croak "Statuses argument must be an arrayref" if ($o->{'statuses'} and ref $o->{'statuses'} ne 'ARRAY');
    _validate_meta($d);

    if (exists $d->{'D'} and (not exists $o->{'depth'} or $o->{'depth'} >= @{$p})) {
        if (ref $d->{'D'} eq 'ARRAY') {
            for (my $i = 0; $i < @{$d->{'D'}}; $i++) {
                push @{$p}, [ exists $d->{'D'}->[$i]->{I} ? $d->{'D'}->[$i]->{I} : $i ];
                dtraverse($d->{'D'}->[$i], $o, $p) or return undef;
                pop @{$p};
            }
        } else { # HASH
            my @keys = keys %{$d->{'D'}};
            @keys = ref $o->{'sortkeys'} eq 'CODE' ? $o->{'sortkeys'}(@keys) : sort @keys if ($o->{'sortkeys'});
            for my $k (@keys) {
                push @{$p}, { 'keys' => [$k] };
                dtraverse($d->{'D'}->{$k}, $o, $p) or return undef;
                pop @{$p};
            }
        }
    } else {
        for ($o->{'statuses'} ? @{$o->{'statuses'}} : keys %{$d}) {
            next unless (exists $d->{$_});
            $o->{'callback'}($d->{$_}, $p, $_, \$d) or return undef;
        }
    }
    return 1;
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
            for my $i (0 .. $#{$d->{'D'}}) {
                my $si = exists $d->{'D'}->[$i]->{'I'} ? $d->{'D'}->[$i]->{'I'} : $i; # use provided index
                if (exists $d->{'D'}->[$i]->{'D'} or exists $d->{'D'}->[$i]->{'N'}) {
                    patch(ref $s->[$si] ? $s->[$si] : \$s->[$si], $d->{'D'}->[$i]);
                } elsif (exists $d->{'D'}->[$i]->{'A'}) {
                    splice @{$s}, $si, 1,
                        (@{$s} > $si ?
                            ($d->{'D'}->[$i]->{'A'}, $s->[$si]) :
                            $d->{'D'}->[$i]->{'A'});
                } elsif (exists $d->{'D'}->[$i]->{'R'}) {
                    splice @{$s}, $si, 1;
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
}

=head1 LIMITATIONS

Struct::Diff fails on structures with loops in references. C<has_circular_ref>
from L<Data::Structure::Util> can help to detect such structures.

Only scalars, refs to scalars, ref to arrays and ref to hashes correctly traversed.
All other data types compared by their references.

No object oriented interface provided.

=head1 AUTHOR

Michael Samoglyadov, C<< <mixas at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-struct-diff at rt.cpan.org>,
or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Struct-Diff>. I will be notified,
and then you'll automatically be notified of progress on your bug as I make
changes.

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

L<Algorithm::Diff>, L<Data::Deep>, L<Data::Diff>, L<Data::Difference>,
L<JSON::MergePatch>

L<Data::Structure::Util>, L<Struct::Path>, L<Struct::Path::PerlStyle>

=head1 LICENSE AND COPYRIGHT

Copyright 2015-2017 Michael Samoglyadov.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

1; # End of Struct::Diff
