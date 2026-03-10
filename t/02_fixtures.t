use v5.40;
use Test2::V0;
use lib 'lib';
use Codec::CBOR;
my $codec = Codec::CBOR->new();

# Fixtures from https://ipld.io/specs/codecs/dag-cbor/fixtures/cross-codec/
my @fixtures = (
    { name => 'array-empty', data => [],                     hex => '80' },
    { name => 'array-2',     data => [2],                    hex => '8102' },
    { name => 'array-255',   data => [255],                  hex => '8118ff' },
    { name => 'array-multi', data => [ 3, 4, 5, 6 ],         hex => '8403040506' },
    { name => 'array-500',   data => [500],                  hex => '811901f4' },
    { name => 'false',       data => Codec::CBOR->false_obj, hex => 'f4' },
    { name => 'true',        data => Codec::CBOR->true_obj,  hex => 'f5' },
    { name => 'null',        data => undef,                  hex => 'f6' },
    { name => 'float-0.5',   data => 0.5,                    hex => 'fb3fe0000000000000' }
);
subtest 'Official Fixtures (Basic)' => sub {
    foreach my $f (@fixtures) {
        my $encoded = $codec->encode( $f->{data} );
        is( unpack( 'H*', $encoded ), $f->{hex}, 'Encoding matches for '.$f->{name} );
        my $decoded = $codec->decode( pack( 'H*', $f->{hex} ) );
        if ( builtin::blessed( $f->{data} ) && $f->{data}->isa('Codec::CBOR::Boolean') ) {
            ok $decoded->isa('Codec::CBOR::Boolean'), 'Decoded is a Boolean object' ;
            is $decoded, $f->{data}, 'Boolean value matches' ;
        }
        else {
            is $decoded, $f->{data}, 'Decoding matches for '.$f->{name} ;
        }
    }
};
subtest 'CID Fixture' => sub {

    # cid-bafkqabiaaebagba: d82a4a00015500050001020304
    my $cid_hex = 'd82a4a00015500050001020304';
    my $decoded = $codec->decode( pack( 'H*', $cid_hex ) );
    is ref $decoded, 'HASH', 'Decoded into hash (default handler)';

    # The default handler in Codec::CBOR strips the 00 prefix, so we must match that
    is unpack( 'H*', $decoded->{cid_raw} ), '015500050001020304', 'cid_raw matches (prefix stripped)';
};
subtest 'DAG-PB Compatibility' => sub {

    # dagpb_Data_some: a26444617461450001020304654c696e6b7380
    # data: {"Data": h'0001020304', "Links": []}
    my $hex  = 'a26444617461450001020304654c696e6b7380';
    my $data = { Data => \pack( 'H*', '0001020304' ), Links => [] };
    is unpack( 'H*', $codec->encode($data) ), $hex, 'dagpb_Data_some encode';
    my $decoded = $codec->decode( pack( 'H*', $hex ) );
    ok !ref $decoded->{Data}, 'Data is raw byte string';
    is unpack( 'H*', $decoded->{Data} ), '0001020304', 'Data value matches';
};
#
done_testing;
