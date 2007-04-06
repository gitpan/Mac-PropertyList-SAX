=head1 NAME

Mac::PropertyList::SAX - work with Mac plists at a low level, fast

=cut

package Mac::PropertyList::SAX;

=head1 SYNOPSIS

See L<Mac::PropertyList>

=head1 DESCRIPTION

L<Mac::PropertyList> is useful, but very slow on large files because it does
XML parsing itself, intead of handing it off to a dedicated parser. This module
uses L<XML::SAX::ParserFactory> to select a parser capable of doing the heavy
lifting, reducing parsing time on large files by a factor of 30 or more.

This module does not, however, replace Mac::PropertyList; in fact, it depends
on it for several package definitions and the plist creation routines. You
should, however, be able to replace all "use Mac::PropertyList" lines with "use
Mac::PropertyList::SAX", making no other changes, and notice an immediate
improvement in performance on large input files.

Be aware that performance will depend largely on the parser that
L<XML::SAX::ParserFactory> selects for you; if you have not installed
L<XML::SAX::Expat> or another fast parser, the default L<XML::SAX::PurePerl>
parser will be used; this will probably give I<worse> performance than
L<Mac::PropertyList>, so ensure that a fast parser is being used before you
complain to me about performance :-). See L<XML::SAX::ParserFactory> for
information on how to set which parser is used.

=cut

use strict;
use warnings;

# Passthrough function
use Mac::PropertyList qw(plist_as_string);
use UNIVERSAL::isa qw(isa);
use XML::SAX::ParserFactory;

use base qw(Exporter);
use vars qw($VERSION @EXPORT_OK %EXPORT_TAGS);
@EXPORT_OK = qw(
    parse_plist 
    parse_plist_fh
    parse_plist_file
    plist_as_string
    create_from_ref
    create_from_hash
    create_from_array
);

%EXPORT_TAGS = (
    all    => \@EXPORT_OK,
    create => [ qw(create_from_ref create_from_hash create_from_array plist_as_string) ],
    parse  => [ qw(parse_plist parse_plist_fh parse_plist_file) ],
);
    
=head1 VERSION

Version 0.50

=cut

$VERSION = '0.50';

=head1 EXPORTS

By default, no functions are exported. Specify individual functions to export
as usual, or use the tags ':all', ':create', and ':parse' for the appropriate
sets of functions (':create' includes the create* functions as well as
plist_as_string; ':parse' includes the parse* functions).

=head1 FUNCTIONS

=over 4

=item parse_plist_file

See L<Mac::PropertyList/parse_plist_file>

=cut

sub parse_plist_file {
    my $file = shift;

    return parse_plist_fh($file) if ref $file;
    
    unless(-e $file) {
        carp("parse_plist_file: file [$file] does not exist!");
        return;
    }
        
    parse_plist_fh(do { local $/; open my($fh), $file; $fh });
}

=item parse_plist_fh

See L<Mac::PropertyList/parse_plist_fh>

=cut

sub parse_plist_fh { my $fh = shift; parse_plist(do { local $/; <$fh> }) }

=item parse_plist

See L<Mac::PropertyList/parse_plist>

=cut

sub parse_plist { _parse(@_) }

=item _parse

Parsing method called by parse_plist_* (internal use only)

=cut

sub _parse {
    my ($data) = @_;

    my $handler = Mac::PropertyList::SAX::Handler->new;
    XML::SAX::ParserFactory->parser(Handler => $handler)->parse_string($data);

    $handler->{struct}
}

=item create_from_ref( HASH_REF | ARRAY_REF )

Create a plist dictionary from an array or hash reference.

The values of the hash can be simple scalars or references. References are
handled recursively. Reference trees containing Mac::PropertyList objects
will be handled correctly (use case: easily combining parsed plists with
"regular" Perl data). All scalars are treated as strings (use Mac::PropertyList
objects to represent integers or other types of scalars).

Returns a string representing the hash in the plist format.

=cut

sub create_from_ref {
    # use "real" local subs to protect internals
    local *_handle_value = sub {
        my ($val) = @_;

        local *_handle_hash = sub {
            my ($hash) = @_;
            Mac::PropertyList::dict->write_open,
                (map { "\t$_" } map {
                    Mac::PropertyList::dict->write_key($_),
                    _handle_value($hash->{$_}) } keys %$hash),
                Mac::PropertyList::dict->write_close
        };

        local *_handle_array = sub {
            my ($array) = @_;
            Mac::PropertyList::array->write_open,
                (map { "\t$_" } map { _handle_value($_) } @$array),
                Mac::PropertyList::array->write_close
        };

        # We could hand off serialization of all Mac::PropertyList::Item objects
        # but there is no 'write' method defined for it (though all its
        # subclasses have one). Let's just handle Scalars, which are safe.
           if (isa $val, 'Mac::PropertyList::Scalar') { $val->write }
        elsif (isa $val,                      'HASH') { _handle_hash ($val) }
        elsif (isa $val,                     'ARRAY') { _handle_array($val) }
        else { Mac::PropertyList::string->new($val)->write }
    };

    $Mac::PropertyList::XML_head .
        (join "\n", _handle_value(shift)) . "\n" .
        $Mac::PropertyList::XML_foot;
}

=item create_from_hash( HASH_REF )

Provided for backward compatibility with Mac::PropertyList: aliases
create_from_ref.

=cut

*create_from_hash = \&create_from_ref;

=item create_from_array( ARRAY_REF )

Provided for backward compatibility with Mac::PropertyList: aliases
create_from_ref.

=cut

*create_from_array = \&create_from_ref;

package Mac::PropertyList::SAX::Handler;

use strict;
use warnings;
use enum qw(EMPTY TOP FREE DICT ARRAY);

use Carp qw(carp croak);
use Alias qw(attr); $Alias::AttrPrefix = 'main::';
use MIME::Base64;
use Text::Trim;

use constant { KEY  => 'key',
               DATA => 'data' };

use base qw(XML::SAX::Base);

sub new {
    # From the plist DTD
    my @complex_types   = qw(array dict);
    my @numerical_types = qw(real integer true false);
    my @simple_types    = qw(data date real integer string true false);
    my @types           = (@complex_types, @numerical_types, @simple_types);

    sub atoh { map { $_ => 1 } @_ }

    my %args = (
        root            => 'plist',

        accum           => "",
        context         => EMPTY,
        key             => undef,
        stack           => [ ],
        struct          => undef,

        complex_types   => { atoh @complex_types   },
        numerical_types => { atoh @numerical_types },
        simple_types    => { atoh @simple_types    },
        types           => { atoh @types           },
    );
    shift->SUPER::new(%args, @_);
}

sub start_element {
    my $self = attr shift;
    my ($data) = @_;
    my $name = $data->{Name};

    if ($::context == EMPTY and $name eq $::root) {
        $::context = TOP;
    } elsif ($::context == TOP) {
        push @::stack, { context => TOP };

        if (!$::types{$name}) {
            croak "Top-level element in plist is not a recognized type";
        } elsif ($name eq 'dict') {
            $::struct = Mac::PropertyList::dict->new;
            $::context = DICT;
        } elsif ($name eq 'array') {
            $::struct = Mac::PropertyList::array->new;
            $::context = ARRAY;
        } else {
            $::context = FREE;
        }
    } elsif ($::complex_types{$name}) {
        push @::stack, {
            key     => $::key,
            context => $::context,
            struct  => $::struct,
        };
        if ($name eq 'array') {
            $::struct = Mac::PropertyList::array->new;
            $::context = ARRAY;
        } elsif ($name eq 'dict') {
            $::struct = Mac::PropertyList::dict->new;
            $::context = DICT;
            undef $::key;
        }
    } elsif ($name ne KEY and !$::simple_types{$name}) {
        # If not a key or a simple value (which require no action here), die
        croak "Received invalid start element $name";
    }
}

sub end_element {
    my $self = attr shift;
    my ($data) = @_;
    my $name = $data->{Name};

    if ($name eq $::root) {
        # Discard plist element
    } elsif ($name eq KEY) {
        $::key = trim $::accum;
        $::accum = "";
    } else {

        sub update_struct {
            my ($context, $structref, $key, $value) = @_;

               if ($context ==  DICT) {       $$structref->{$key} = $value }
            elsif ($context == ARRAY) { push @$$structref,          $value }
            elsif ($context ==  FREE) {       $$structref         = $value }
        }

        if ($::complex_types{$name}) {
            my $elt = pop @::stack;
            if ($elt->{context} != TOP) {
                my $oldstruct = $::struct;
                ($::struct, $::key, $::context) = @{$elt}{qw(struct key context)};

                update_struct($::context, \$::struct, $::key, $oldstruct);

                undef $::key;
            }
        } else {
            # Wrap accumulated character data in an object
            my $value = "Mac::PropertyList::$name"->new(
                $name eq DATA ? MIME::Base64::decode_base64($::accum)
                              : trim $::accum);

            update_struct($::context, \$::struct, $::key, $value);
        }

        $::accum = "";
    }
}

sub characters { shift->{accum} .= shift->{Data} }

1;

__END__

=back

=head1 BUGS / CAVEATS / TODO

Behavior is not I<exactly> the same as L<Mac::PropertyList>'s; specifically, in
the case of special characters, such as accented characters and ampersands.
Ampersands encoded (for example, as '&#38;') in the original property list will
be decoded by the XML parser in this module; L<Mac::PropertyList> leaves them
as-is. Also, accented/special characters are converted into '\x{ff}' sequences
by the XML parser in this module, but are preserved in their original encoding
by L<Mac::PropertyList>. The differences may be evident when creating a plist
file from a parsed data structure, but this has not yet been tested.

The behavior of create_from_hash and create_from_array has changed: these
functions (which are really just aliases to the new create_from_ref function)
are now capable of recursively serializing complex data structures. For inputs
that Mac::PropertyList's create_from_* functions handlsd, the output should be
the same, but the addition of functionality means that the reverse is not true.

Please report any bugs or feature requests to C<bug-mac-propertylist-sax at
rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Mac-PropertyList-SAX>.  I will
be notified, and then you'll automatically be notified of progress on your bug
as I make changes.

=head1 SUPPORT

Please contact the L<AUTHOR> with bug reports or feature requests.

=head1 AUTHOR

Darren M. Kulp, C<< <kulp @ cpan.org> >>

=head1 THANKS

brian d foy, who created the L<Mac::PropertyList> module whose tests were
appropriated for this module.

=head1 SEE ALSO

L<Mac::PropertyList>, the inspiration for this module.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Darren Kulp

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.

=cut

# vi: set et ts=4 sw=4: #
