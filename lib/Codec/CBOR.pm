use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Codec::CBOR v0.0.1 {
    field %tag_handlers = (
        42 => sub ($data) {    # Default Tag 42 handler(generic)
            if ( !ref $data && substr( $data, 0, 1 ) eq "\x00" ) {
                return { cid_raw => substr( $data, 1 ) };
            }
            return $data;
        }
    );
    field %class_handlers;
    method add_tag_handler   ( $tag, $cb )   { $tag_handlers{$tag}     = $cb }
    method add_class_handler ( $class, $cb ) { $class_handlers{$class} = $cb }
    method encode            ($data)         { return $self->_encode_item($data) }

    method decode ($input) {
        if ( !ref $input ) {
            open my $fh, "<:raw", \$input;
            return $self->_decode_item($fh);
        }
        return $self->_decode_item($input);
    }

    method decode_sequence ($input) {
        my $fh;
        if ( !ref $input ) {
            open $fh, "<:raw", \$input;
        }
        else {
            $fh = $input;
        }
        my @items;
        while (1) {
            my $item;
            try { $item = $self->_decode_item($fh); } catch ($e) {
                ;
            }
            last if $@ || !defined $item;
            push @items, $item;
            last if eof($fh);
        }
        return wantarray ? @items : \@items;
    }

    method _encode_item ($item) {
        return pack( 'C', 0xf6 ) unless defined $item;    # null
        my $ref = ref($item);
        if ( !$ref ) {

            # Integer or UTF-8 String
            return $self->_encode_int($item) if $item =~ /^-?\d+$/ && length($item) < 20;
            return $self->_encode_utf8($item);
        }
        return $self->_encode_bytes($$item) if $ref eq 'SCALAR';
        return $self->_encode_array($item)  if $ref eq 'ARRAY';
        return $self->_encode_hash($item)   if $ref eq 'HASH';

        # Handle registered classes (like CID)
        for my $class ( keys %class_handlers ) {
            return $class_handlers{$class}->( $self, $item ) if builtin::blessed($item) && $item->isa($class);
        }

        # Fallback for generic CID-like objects if not registered
        if ( blessed($item) && $item->can('raw') ) {
            my $raw = $item->raw;
            return pack( 'C', 0xd8 ) . pack( 'C', 42 ) . $self->_encode_bytes( "\x00" . $raw );
        }
        die "Codec::CBOR: Cannot encode $ref";
    }

    method _encode_int ($val) {
        return $self->_encode_header( 0, $val ) if $val >= 0;
        $self->_encode_header( 1, -1 - $val );
    }

    method _encode_header ( $major, $val ) {
        return pack( 'C', ( $major << 5 ) | $val ) if $val < 24;
        return pack( 'CC', ( $major << 5 ) | 24, $val ) if $val < 256;
        return pack( 'Cn', ( $major << 5 ) | 25, $val ) if $val < 65536;
        return pack( 'CN', ( $major << 5 ) | 26, $val ) if $val < 4294967296;
        pack( 'CQ>', ( $major << 5 ) | 27, $val );
    }

    method _encode_utf8 ($str) {
        my $encoded = $str;
        utf8::encode($encoded) if utf8::is_utf8($encoded);
        $self->_encode_header( 3, length($encoded) ) . $encoded;
    }
    method _encode_bytes ($bytes) { $self->_encode_header( 2, length($bytes) ) . $bytes }

    method _encode_array ($arr) {
        my $out = $self->_encode_header( 4, scalar @$arr );
        $out .= $self->_encode_item($_) for @$arr;
        $out;
    }

    method _encode_hash ($hash) {    # DAG-CBOR deterministic sort: length first, then lexical
        my @keys = sort { length($a) <=> length($b) || $a cmp $b } keys %$hash;
        my $out  = $self->_encode_header( 5, scalar @keys );
        for my $k (@keys) {
            $out .= $self->_encode_utf8($k);
            $out .= $self->_encode_item( $hash->{$k} );
        }
        $out;
    }

    method _decode_item ($fh) {
        return undef unless defined $fh;
        return undef if eof($fh);
        read( $fh, my $byte, 1 ) or return undef;
        my $b     = ord($byte);
        my $major = $b >> 5;
        my $info  = $b & 0x1f;
        if ( $major == 0 ) { return $self->_decode_value( $info, $fh ); }
        if ( $major == 1 ) { return -1 - $self->_decode_value( $info, $fh ); }

        if ( $major == 2 ) {    # Byte string
            my $len = $self->_decode_value( $info, $fh );
            read( $fh, my $buf, $len );
            return $buf;
        }
        if ( $major == 3 ) {    # UTF-8 string
            my $len = $self->_decode_value( $info, $fh );
            read( $fh, my $buf, $len );
            my $decoded = $buf;
            try {
                die 'Invalid UTF-8' unless utf8::decode($decoded)
            }
            catch ($e) {

                #~ warn $e;
                return $buf;    # Return raw bytes if decoding fails
            }
            return $decoded;
        }
        if ( $major == 4 ) {    # Array
            my $len = $self->_decode_value( $info, $fh );
            my @arr;
            push @arr, $self->_decode_item($fh) for 1 .. $len;
            return \@arr;
        }
        if ( $major == 5 ) {    # Map
            my $len = $self->_decode_value( $info, $fh );
            my %hash;
            for ( 1 .. $len ) {
                my $k = $self->_decode_item($fh);
                my $v = $self->_decode_item($fh);
                $hash{$k} = $v;
            }
            return \%hash;
        }
        if ( $major == 6 ) {    # Tag
            my $tag = $self->_decode_value( $info, $fh );
            my $val = $self->_decode_item($fh);
            return $tag_handlers{$tag}->($val) if exists $tag_handlers{$tag};
            return $val;        # Return inner value if no handler
        }
        if ( $major == 7 ) {    # Simple
            return 0     if $info == 20;    # False
            return 1     if $info == 21;    # True
            return undef if $info == 22;    # Null
            return $self->_decode_value( $info, $fh );
        }
        die 'Codec::CBOR: Unsupported major type ' . $major;
    }

    method _decode_value ( $info, $fh ) {
        if ( $info < 24 )  { return $info; }
        if ( $info == 24 ) { read( $fh, my $b, 1 ); return unpack( "C",  $b ); }
        if ( $info == 25 ) { read( $fh, my $b, 2 ); return unpack( "n",  $b ); }
        if ( $info == 26 ) { read( $fh, my $b, 4 ); return unpack( "N",  $b ); }
        if ( $info == 27 ) { read( $fh, my $b, 8 ); return unpack( "Q>", $b ); }
        die 'Codec::CBOR: Indefinite length or invalid info ' . $info;
    }
};
#
1;
