use Modern::Perl;
use Test::More;

sub canonical_mapping {
    my ( $item_level, $items, $biblios ) = @_;
    my %seen;
    my $source = $item_level ? $items : $biblios;
    return [ grep {
        defined $_->[1] && length $_->[1]
            && !$seen{ join "\x1f", map { defined $_ ? $_ : '' } @$_ }++
    } @$source ];
}

sub filter_lifecycle {
    my ( $rows, $mapping, $selected ) = @_;
    return [@$rows] unless defined $selected && length $selected;
    my %allowed = map { $_->[1] eq $selected ? ($_->[0] => 1) : () } @$mapping;
    return [ grep { $allowed{ $_->{biblio_id} } } @$rows ];
}

my $items = [
    [ 1, 'EBOOK' ], [ 1, 'EBOOK' ], [ 1, 'BOOK' ],
    [ 2, 'BOOK' ], [ 3, undef ],
];
my $biblios = [ [ 1, 'BOOK' ], [ 2, 'EBOOK' ], [ 3, undef ] ];
my $rows = [
    { id => 10, biblio_id => 1 }, { id => 11, biblio_id => 2 },
    { id => 12, biblio_id => 3 }, { id => 13, biblio_id => 4 },
];

my $item_map = canonical_mapping( 1, $items, $biblios );
is scalar( grep { $_->[0] == 1 && $_->[1] eq 'EBOOK' } @$item_map ), 1,
    'multiple items do not duplicate a biblio/type mapping';
is_deeply [ map { $_->{id} } @{ filter_lifecycle($rows, $item_map, 'EBOOK') } ],
    [10], 'EBOOK selected uses item-level type';
is_deeply [ map { $_->{id} } @{ filter_lifecycle($rows, $item_map, 'BOOK') } ],
    [10,11], 'another item type selected uses item-level type';
is scalar(@{ filter_lifecycle($rows, $item_map, '') }), 4,
    'empty selection means all item types including unmapped biblios';

my $record_map = canonical_mapping( 0, $items, $biblios );
is_deeply [ map { $_->{id} } @{ filter_lifecycle($rows, $record_map, 'EBOOK') } ],
    [11], 'record-level item type is honored';
is_deeply [ map { $_->{id} } @{ filter_lifecycle($rows, $record_map, 'BOOK') } ],
    [10], 'record-level alternate type is honored';
is scalar(@{ filter_lifecycle($rows, $record_map, 'EBOOK') }), 1,
    'biblios without a mapping do not match a selected type';
done_testing;
