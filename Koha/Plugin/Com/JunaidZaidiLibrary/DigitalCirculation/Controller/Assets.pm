package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Assets;

use Mojo::Base 'Mojolicious::Controller';

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;

# Exact logical identifiers only. Values are packaged relative paths and MIME types.
# Do not derive filesystem paths from untrusted input outside this map.
my %LOGICAL_ASSETS = (
    'jzl-digital-circulation-js' => {
        path         => 'static/js/jzl-digital-circulation.js',
        content_type => 'application/javascript; charset=utf-8',
    },
    'jzl-digital-circulation-css' => {
        path         => 'static/css/jzl-digital-circulation.css',
        content_type => 'text/css; charset=utf-8',
    },
);

sub serve {
    my ($c) = @_;

    my $asset_id = $c->param('asset');
    $asset_id = '' unless defined $asset_id;

    # Exact allowlist only. Reject traversal, separators, extensions, and unknowns.
    my $spec = $LOGICAL_ASSETS{$asset_id};
    return $c->render( status => 404, text => 'Not found' ) unless $spec;

    my $plugin = Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation->new;
    my $body   = $plugin->mbf_read( $spec->{path} );

    $c->res->headers->content_type( $spec->{content_type} );
    $c->res->headers->header( 'X-Content-Type-Options' => 'nosniff' );
    return $c->render( data => $body );
}

1;
