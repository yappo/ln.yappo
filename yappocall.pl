use strict;
use warnings;

use Furl;
use Plack::Request;

my $owner_message_file = '/tmp/yappocall_owner_message.txt';
my $owner_name         = $ENV{YAPPOCALL_OWNER_NAME};
my $lnyappo_endpoint   = $ENV{YAPPOCALL_LNYAPPO_ENDPOINT};
my $lnyappo_appname    = $ENV{YAPPOCALL_LNYAPPO_APPNAME};
my $lnyappo_api_token  = $ENV{YAPPOCALL_LNYAPPO_API_TOKEN};

my $furl = Furl->new( agent => 'Yappocall/1.00' );

sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $res = $req->new_response(200);
    if ($req->method eq 'POST') {
        if ($req->path eq '/post') {
            do_post($req, $res);
        } elsif ($req->path eq '/callback') {
            do_callback($req, $res);
        }
    } elsif ($req->method eq 'GET') {
        if ($req->path eq '/') {
            do_index($req, $res);
        }
    }

    $res->finalize;
};

sub do_index {
    my($req, $res) = @_;

    my $owner_message = '';
    if (-e $owner_message_file) {
        my $text = do {
            local $/;
            open my $fh, '<', $owner_message_file;
            <$fh>;
        };
        $owner_message = "$owner_name からメッセージが有るよ。<br>'$text'<br>\n";
    }

    $res->header( 'Content-Type' => 'text/html; charset=utf-8' );
    $res->body(<<HTML);
<html>
  <head><title>$owner_name Call</title></head>
  <body>
    <h1>$owner_name Call</h1>
    いつでもどこから $owner_name の LINE に呼び出せちゃう便利サイト。

    <h2>send to $owner_name</h2>
    $owner_message
    <form action="./post" method="post">
      message: <textarea name="message"></textarea><br>
      <input type="submit" value="send to LINE">
    </form>
  </body>
<html>
HTML
}

sub do_post {
    my($req, $res) = @_;

    $furl->post($lnyappo_endpoint, [], [
        appname   => $lnyappo_appname,
        api_token => $lnyappo_api_token,
        message   => $req->param('message'),
    ]);

    $res->body('done');
}

sub do_callback {
    my($req, $res) = @_;

    unless ($req->param('appname') eq $lnyappo_appname && $req->param('api_token') eq $lnyappo_api_token) {
        $res->body('token error');
        return;
    }

    open my $fh, '>', $owner_message_file or do {
        $res->body('write error');
        return;
    };
    print $fh $req->param('message');

    $res->body('done');
}
