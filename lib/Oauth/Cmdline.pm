###########################################
package Oauth::Cmdline;
###########################################
use strict;
use warnings;
use Moo;
use URI;
use YAML qw( DumpFile LoadFile );
use HTTP::Request::Common;
use LWP::UserAgent;
use Log::Log4perl qw(:easy);
use JSON qw( from_json );

our $VERSION = "0.01";

has client_id     => ( is => "ro" );
has client_secret => ( is => "ro" );
has local_uri      => ( 
  is      => "rw",
  default => "http://localhost:8082",
);
has homedir => ( 
  is      => "ro",
  default => glob '~',
);
has login_uri => ( is => "rw" );
has site      => ( is => "rw" );
has scope     => ( is => "rw" );
has token_uri => ( is => "rw" );
has redir_uri => ( is => "rw" );

###########################################
sub redirect_uri {
###########################################
    my( $self ) = @_;

    return $self->local_uri . "/callback";
}

###########################################
sub cache_file_path {
###########################################
    my( $self ) = @_;

      # creds saved  ~/.[site].yml
    return $self->homedir . "/." .
           $self->site . ".yml";
}

###########################################
sub full_login_uri {
###########################################
    my( $self ) = @_;

    my $full_login_uri = URI->new( $self->login_uri );

    $full_login_uri->query_form (
      client_id     => $self->client_id(),
      response_type => "code",
      redirect_uri  => $self->redirect_uri(),
      scope         => $self->scope(),
    );

    return $full_login_uri;
}

###########################################
sub access_token {
###########################################
    my( $self ) = @_;

    if( $self->token_expired() ) {
        $self->token_refresh();
    }

    my $cache = $self->cache_read();
    return $cache->{ access_token };
}

###########################################
sub token_refresh {
###########################################
    my( $self ) = @_;

    DEBUG "Refreshing access token";

    my $cache = $self->cache_read();

    my $req = &HTTP::Request::Common::POST(
        $self->token_uri,
        [
            refresh_token =>
            $cache->{ refresh_token },
            client_id     =>
            $cache->{ client_id },
            client_secret =>
            $cache->{ client_secret },
            grant_type    => 'refresh_token',
        ]
    );

    my $ua = LWP::UserAgent->new();
    my $resp = $ua->request($req);

    if( $resp->is_success() ) {
        my $data = 
        from_json( $resp->content() );

        DEBUG "Token refreshed, will expire in $data->{ expires_in } seconds";

        $cache->{ access_token } = $data->{ access_token };
        $cache->{ expires }      = $data->{ expires_in } + time();

        $self->cache_write( $cache );
    }

    return 1;

    ERROR "Token refresh failed: ", $resp->status_line();
    return undef;
}

###########################################
sub token_expired {
###########################################
    my( $self ) = @_;

    my $cache = $self->cache_read();

    my $time_remaining = $cache->{ expires } - time();

    if( $time_remaining < 300 ) {
        if( $time_remaining < 0 ) {
            DEBUG "Token expired ", -$time_remaining, " seconds ago";
        } else {
            DEBUG "Token will expire in $time_remaining seconds";
        }

        DEBUG "Token needs to be refreshed.";
        return 1;
    }

    return 0;
}

###########################################
sub cache_read {
###########################################
    my( $self ) = @_;

    if( -f $self->cache_file_path ) {
        LOGDIE "Cache file ", $self->cache_file_path, " not found. ",
          "See GETTING STARTED in the docs for how to get started.";
    }

    return LoadFile $self->cache_file_path;
}

###########################################
sub cache_write {
###########################################
    my( $self, $cache ) = @_;

    umask 0177;
    return DumpFile $self->cache_file_path, $cache;
}

###########################################
sub tokens_get {
###########################################
    my( $self, $code ) = @_;

    my $req = &HTTP::Request::Common::POST(
        $self->token_uri,
        [
            code          => $code,
            client_id     => $self->client_id,
            client_secret => $self->client_secret,
            redirect_uri  => $self->redirect_uri,
            grant_type    => 'authorization_code',
        ]
    );

    my $ua = LWP::UserAgent->new();
    my $resp = $ua->request($req);

    if( $resp->is_success() ) {
        my $data = 
        from_json( $resp->content() );

        return ( $data->{ access_token }, 
            $data->{ refresh_token },
            $data->{ expires_in } );
    }

    LOGDIE $resp->status_line();
    return undef;
}

###########################################
sub tokens_collect {
###########################################
    my( $self, $code ) = @_;

    my( $access_token, $refresh_token,
        $expires_in ) = $self->tokens_get( $code );

    my $cache = {
        access_token  => $access_token,
        refresh_token => $refresh_token,
        client_id     => $self->client_id,
        client_secret => $self->client_secret,
        expires       => time() + $expires_in,
    };

    $self->cache_write( $cache );
}

1;

__END__

=head1 NAME

Oauth::Cmdline - Oauth2 for command line applications using web services

=head1 SYNOPSIS

    my $oauth = Oauth::Cmdline->new( site => "spotify" );
    $oauth->access_token();

=head1 DESCRIPTION

Oauth::Cmdline helps standalone command line scripts to deal with 
web services requiring OAuth access tokens.

=head1 GETTING STARTED

To obtain the initial set of access and refresh tokens from the 
Oauth-controlled site, you need to register your command line app
with the site and you'll get a "Client ID" and a "Client Secret" 
in return. Also, the site's SDK will point out the "Login URI" and
the "Token URI" to be used with the particular service.
Then, run the following script (the example uses the Spotify web service)

    use Oauth::Cmdline;
    use Oauth::Cmdline::Mojo;

    my $oauth = Oauth::Cmdline->new(
        client_id     => "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        client_secret => "YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY",
        login_uri     => "https://accounts.spotify.com/authorize",
        token_uri     => "https://accounts.spotify.com/api/token",
        site          => "spotify",
        scope         => "user-read-private",
    );
    
    my $app = Oauth::Cmdline::Mojo->new(
        oauth => $oauth,
    );
    
    $app->start( 'daemon', '-l', $oauth->local_uri );

and point a browser to the URL displayed at startup. Clicking on the
link displayed will take you to the Oauth-controlled site, where you need
to log in and allow the app access to the user data, following the flow
provided on the site. The site will then redirect to the web server
started by the script, which will receive an initial access token with 
an expiration date and a refresh token from the site, and store it locally
in the cache file in your home directory (~/.sitename.yml).

=head1 LEGALESE

Copyright 2014 by Mike Schilli, all rights reserved.
This program is free software, you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 AUTHOR

2014, Mike Schilli <cpan@perlmeister.com>
