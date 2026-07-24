use Modern::Perl;
use Test::More;
use lib '.';

BEGIN {
    package Mojolicious::Controller;
    sub new { bless {}, $_[0] }
    $INC{'Mojolicious/Controller.pm'} = __FILE__;

    package Mojo::Base;
    sub import {
        my ( $class, $base ) = @_;
        return unless $base;
        my $caller = caller;
        no strict 'refs';
        @{"${caller}::ISA"} = ($base);
    }
    $INC{'Mojo/Base.pm'} = __FILE__;

    package Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation;
    our $LAST_MBF_PATH;
    our %MBF_BYTES = (
        'static/js/jzl-digital-circulation.js'  => "/*js-fixture*/\n",
        'static/css/jzl-digital-circulation.css' => "/*css-fixture*/\n",
    );
    sub new { bless {}, $_[0] }
    sub mbf_read {
        my ( $self, $path ) = @_;
        $LAST_MBF_PATH = $path;
        die "unexpected path $path\n" unless exists $MBF_BYTES{$path};
        return $MBF_BYTES{$path};
    }
    $INC{'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation.pm'} = __FILE__;
}

use Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Assets;

{
    package Local::AssetHeaders;
    sub new {
        my ( $class, $values ) = @_;
        return bless {
            values => {
                map { lc($_) => $values->{$_} }
                  keys %{ $values || {} }
            }
        }, $class;
    }
    sub header {
        my ( $self, $name, $value ) = @_;
        $self->{values}{ lc $name } = $value if @_ == 3;
        return $self->{values}{ lc $name };
    }
    sub content_type {
        my ( $self, $value ) = @_;
        return $self->header( 'Content-Type', $value ) if @_ == 2;
        return $self->header('Content-Type');
    }

    package Local::AssetResponse;
    sub new { bless { headers => Local::AssetHeaders->new }, $_[0] }
    sub headers { return shift->{headers} }

    package Local::AssetController;
    our @ISA = (
        'Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::Controller::Assets'
    );
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            asset  => $args{asset},
            res    => Local::AssetResponse->new,
            render => undef,
        }, $class;
    }
    sub param {
        my ( $self, $name ) = @_;
        return $self->{asset} if $name eq 'asset';
        return;
    }
    sub res { return shift->{res} }
    sub render {
        my ( $self, %args ) = @_;
        $self->{render} = {%args};
        return $self;
    }
}

sub serve_asset {
    my ($asset) = @_;
    $Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::LAST_MBF_PATH = undef;
    my $c = Local::AssetController->new( asset => $asset );
    $c->serve;
    return $c;
}

my $js = serve_asset('jzl-digital-circulation-js');
is $js->{render}{status}, undef, 'JavaScript logical asset succeeds without status override';
is $js->{render}{data}, "/*js-fixture*/\n", 'JavaScript logical asset returns exact packaged bytes';
is $Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::LAST_MBF_PATH,
  'static/js/jzl-digital-circulation.js',
  'JavaScript logical asset resolves only to the packaged JS file';
is $js->res->headers->content_type,
  'application/javascript; charset=utf-8',
  'JavaScript MIME type is application/javascript with charset';
is $js->res->headers->header('X-Content-Type-Options'), 'nosniff',
  'JavaScript response sets nosniff';

my $css = serve_asset('jzl-digital-circulation-css');
is $css->{render}{data}, "/*css-fixture*/\n", 'CSS logical asset returns exact packaged bytes';
is $Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::LAST_MBF_PATH,
  'static/css/jzl-digital-circulation.css',
  'CSS logical asset resolves only to the packaged CSS file';
is $css->res->headers->content_type, 'text/css; charset=utf-8',
  'CSS MIME type is text/css with charset';
is $css->res->headers->header('X-Content-Type-Options'), 'nosniff',
  'CSS response sets nosniff';

for my $bad (
    undef, '', 'unknown',
    'jzl-digital-circulation.js',
    'jzl-digital-circulation.css',
    '../static/js/jzl-digital-circulation.js',
    '..%2fstatic%2fjs%2fjzl-digital-circulation.js',
    '/etc/passwd',
    'C:\\Windows\\win.ini',
    '\\\\server\\share\\file',
    "jzl-digital-circulation-js\0.js",
    'jzl-digital-circulation-js.js',
    'static/js/jzl-digital-circulation.js',
  )
{
    my $label = defined $bad ? $bad : '<undef>';
    $label =~ s/\0/\\0/g;
    my $c = serve_asset($bad);
    is $c->{render}{status}, 404, "unknown/traversal asset returns 404 ($label)";
    is $c->{render}{text}, 'Not found', "404 body is generic ($label)";
    is $Koha::Plugin::Com::JunaidZaidiLibrary::DigitalCirculation::LAST_MBF_PATH,
      undef, "mbf_read is not called for rejected asset ($label)";
    unlike( ( $c->{render}{text} // '' ) . ( $c->{render}{data} // '' ),
        qr{(?i)(?:/var/|/home/|\\\\|[A-Za-z]:\\|static/|passwd|win\.ini)},
        "rejected response does not disclose a path ($label)" );
}

# Authorization contract remains on OpenAPI (empty permissions object),
# unchanged relative to request/decision endpoints.
use JSON qw(decode_json);
open my $fh, '<',
  'Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json'
  or die $!;
my $api = decode_json( do { local $/; <$fh> } );
close $fh;
ok exists $api->{'/assets/{asset}'}{get}{'x-koha-authorization'}{permissions},
  'asset route retains x-koha-authorization permissions object';
is_deeply $api->{'/assets/{asset}'}{get}{'x-koha-authorization'}{permissions},
  {}, 'asset authorization permissions object is unchanged (empty)';
ok exists $api->{'/requests'}{post},
  'request creation route remains present after asset correction';
ok exists $api->{'/requests/{request_id}/decision'}{post},
  'staff decision route remains present after asset correction';

done_testing;
