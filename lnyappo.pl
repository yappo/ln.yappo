use strict;
use warnings;

use DBI;
use Digest::SHA 'hmac_sha256_base64';
use Encode;
use Furl;
use JSON::PP;
use Plack::Request;
use String::Random;

my $dbh = DBI->connect('dbi:SQLite:dbname=lnyappo.db', '', '');
my $string_gen = String::Random->new;
my $furl = Furl->new( agent => 'LiNe Yappo/1.00' );

my $registration_secret = $ENV{LNYAPPO_REGISTRATION_SECRET}; # この LINE Bot は、ここで設定した文字列を受け付けると、ユーザの登録を行います

my $channel_id     = $ENV{LINE_CHANNEL_ID};
my $channel_secret = $ENV{LINE_CHANNEL_SECRET};
my $bot_mid        = $ENV{LINE_BOT_MID};

my $line_bot_api_endpoint = 'https://trialbot-api.line.me/v1/events';

sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $res = $req->new_response(200);

    if ($req->method eq 'POST') {
        if ($req->path eq '/linebot/callback') {
            if (signature_validation($req)) {
                callback($req);
            }
        } elsif ($req->path eq '/send') {
            do_send($req, $res);
        } elsif ($req->path eq '/add_callback') {
            do_add_callback($req, $res);
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
    $res->header( 'Content-Type' => 'text/html; charset=utf-8' );
    $res->body(<<HTML);
<html>
  <head><title>ln.yappo</title></head>
  <body>
    <h1>ln.yappo</h1>
    <h2>API Spec</h2>
    <table border="1">
      <tr>
        <td>endpoint</td>
        <td>method://hostname:port/send</td>
      </tr>
      <tr>
        <td>method</td>
        <td>POST</td>
      </tr>
      <tr>
        <td>Content-Type</td>
        <td>application/x-www-form-urlencoded</td>
      </tr>
      <tr>
        <td>params</td>
        <td>
          appname: LINE 上で設定した app の名前
          api_token: このアプリを動かしている LINE Bot と友達になり LNYAPPO_REGISTRATION_SECRET で設定した文章を LNE Bot に送信すると api_token が生成されるので、それを利用します。<br>
          message: LINE に送信したいメッセージ
        </td>
      </tr>
    <table>
    <h2>quick send form</h2>
    <form action="./send" method="post">
      appname: <input name="appname"><br>
      api_token: <input name="api_token"><br>
      message: <textarea name="message"></textarea><br>
      <input type="submit" value="send to LINE">
    </form>

    <h2>add callback url</h2>
    LINE の talk 画面で send コマンドを使うと<br>
    登録した callback url に対して application/x-www-form-urlencoded で POST します。<br>
    appname, api_token, message が送信されるので、どのユーザからのメッセージかをハンドリング可能です。<br>

    <br>
    <form action="./add_callback" method="post">
      appname: <input name="appname"><br>
      api_token: <input name="api_token"><br>
      callback url: <input name="url"><br>
      <input type="submit" value="save callback url">
    </form>

  </body>
<html>
HTML
}

sub do_send {
    my($req, $res) = @_;

    my $api_token = $req->param('api_token');
    my $appname   = $req->param('appname');
    my $message   = $req->param('message');

    unless ($appname && $api_token && $message) {
        $res->body('{"status":500,"message":"Bad request."}');
        return;
    }

    my $activate_mid = get_activate_mid_by_api($appname, $api_token);
    unless ($activate_mid) {
        $res->body('{"status":404,"message":"appname or api_token is not exists."}');
        return;
    }

    my $line_res = send_text($activate_mid->{mid}, decode( utf8 => "from: $appname\n$message" ));
    $res->header( 'Content-Type' => $line_res->header('Content-Type') );
    $res->body($line_res->content);
}

sub do_add_callback {
    my($req, $res) = @_;

    my $api_token = $req->param('api_token');
    my $appname   = $req->param('appname');
    my $url       = $req->param('url');

    unless ($appname && $api_token && $url) {
        $res->body('{"status":500,"message":"Bad request."}');
        return;
    }

    my $activate_mid = get_activate_mid_by_api($appname, $api_token);
    unless ($activate_mid) {
        $res->body('{"status":404,"message":"appname or api_token is not exists."}');
        return;
    }

    save_callback_url($activate_mid->{id}, $url);
    my $line_res = send_text($activate_mid->{mid}, sprintf("'%s' app's callback url was registered by Web app.\nurl is '%s'", $appname, $url));
    $res->header( 'Content-Type' => $line_res->header('Content-Type') );
    $res->body('{"status":200,"message":"Succeed."}');
}


sub signature_validation {
    my $req = shift;
    my $json = $req->content or return;
    my $signature = $req->header('X-LINE-ChannelSignature');
    $signature =~ s/=+\z//;
    $signature eq hmac_sha256_base64($json, $channel_secret);
}

sub callback {
    my $req = shift;
    my $json = $req->content or return;

    my $data = decode_json $json;
    for my $message (@{ $data->{result} }) {
        next unless validation_message($message);

        my $text = $message->{content}{text};
        if ($text =~ /\A$registration_secret\s+(.+)\z/) {
            my $command_line = $1;
            warn "COMMAND LINE: $command_line";
            if ($command_line =~ /\A(add|del|send)\s+(.+)\z/) {
                my($command, $body) = ($1, $2);
                warn "COMMAND: $command BODY: $body";
                if ($command eq 'add') {
                    registration_app($message, $text, $body);
                } elsif ($command eq 'del') {
                    remove_app($message, $body);
                } elsif ($command eq 'send') {
                    send_callback($message, split(/\s+/, $body));
                }
            } elsif ($command_line eq 'list') {
                send_applist($message);
            } elsif ($command_line eq 'help') {
                send_help($message);
            }
        }
    }
}

sub validation_message {
    my $message = shift;
    return unless $message->{eventType}            eq '138311609000106303';
    return unless $message->{fromChannel}          eq '1341301815';
    return unless $message->{toChannel}            eq $channel_id;
    return unless $message->{content}{toType}      == 1;
    return unless $message->{content}{contentType} == 1;
    my $sent_me = 0;
    for my $mid (@{ $message->{content}{to} }) {
        $sent_me++ if $mid eq $bot_mid;
    }
    return unless $sent_me;
    return 1;
}

sub registration_app {
    my($message, $used_secret, $appname) = @_;
    my $mid = $message->{content}{from};

    my $activate_mid = get_activate_mid_by_mid($mid, $appname);
    if ($activate_mid) {
        send_text($mid, sprintf("You are registered.\nYour '%s' app's api_token is '%s'.", $activate_mid->{api_app}, $activate_mid->{api_token}));
        return;
    }
    activate($mid, $used_secret, $appname);
}

sub remove_app {
    my($message, $appname) = @_;
    my $mid = $message->{content}{from};

    my $activate_mid = get_activate_mid_by_mid_with_errorhandling($mid, $appname);
    return unless $activate_mid;

    remove_callback_url($activate_mid->{id});
    remove_activate_mid($activate_mid->{id});
    send_text($mid, 'Succeed');
}

sub send_callback {
    my($message, $appname, $text) = @_;
    my $mid = $message->{content}{from};

    my $activate_mid = get_activate_mid_by_mid_with_errorhandling($mid, $appname);
    return unless $activate_mid;

    my $callback_url = get_callback_url($activate_mid->{id});
    unless ($callback_url) {
        send_text($mid, "callback url is not found.\nPlease activatesave your apps's callback url on Web app.");
        return;
    }

    my $res = $furl->post($callback_url->{url}, [], [
        appname   => $appname,
        api_token => $activate_mid->{api_token},
        message   => encode( utf8 => $text ),
    ]);
    if ($res->is_success) {
        send_text($mid, sprintf("Succeed.\ncode: %s\nbody: %s", $res->code, $res->content));
    } else {
        send_text($mid, sprintf("Failed.\ncode: %s\nbody: %s", $res->code, $res->content));
    }
}

sub send_applist {
    my($message) = @_;
    my $mid = $message->{content}{from};

    my $body = "Your registered app list.\n";
    my $rows = retrieve_ctivate_mids_by_mid($mid);
    my $i = 0;
    for my $row (@{ $rows }) {
        $body .= sprintf("%03d. %s\napi_token: %s", ++$i, $row->{api_app}, $row->{api_token});
        $body .= "\n    callback url: " . $row->{url} if $row->{url};
    }
    if (@{ $rows} == 0) {
        $body .= "Your app is not registered.";
    }

    send_text($mid, $body);
}

sub send_help {
    my($message) = @_;
    my $mid = $message->{content}{from};
    send_text($mid, <<'HELP');
ln.yappo Help

1. add
  > $SECRET add $yourAppName

2. delete
  > $SECRET del $yourAppName

3. send message to callback url
  > $SECRET send $yourAppName $message

4. list
  > $SECRET list

5. help
  > $SECRET help
HELP
}


sub get_activate_mid_by_mid_with_errorhandling {
    my($mid, $appname) = @_;

    my $activate_mid = get_activate_mid_by_mid($mid, $appname);
    unless ($activate_mid) {
        send_text($mid, "activate data is not found.\nPlease activate your apps.");
        return;
    }
}


sub get_activate_mid_by_mid {
    my($mid, $api_app) = @_;

    my $rows = $dbh->selectall_arrayref('SELECT * FROM activate_mid WHERE mid=? AND api_app=?', { Slice => +{} }, $mid, $api_app);
    return $rows->[0];
}

sub get_activate_mid_by_api {
    my($api_app, $api_token) = @_;

    my $rows = $dbh->selectall_arrayref('SELECT * FROM activate_mid WHERE api_app=? AND api_token=?', { Slice => +{} }, $api_app, $api_token);
    return $rows->[0];
}

sub retrieve_ctivate_mids_by_mid {
    my($mid) = @_;
    $dbh->selectall_arrayref(
        'SELECT activate_mid.*, callback_url.url FROM activate_mid
LEFT JOIN callback_url ON activate_mid.id = callback_url.activate_mid_id
WHERE mid=?
ORDER BY activate_mid.id', { Slice => +{} }, $mid);
}

sub activate {
    my($mid, $used_secret, $api_app) = @_;

    for (1..5) {
        my $api_token = $string_gen->randregex('[a-zA-Z0-9]{32}');
        next if get_activate_mid_by_api($api_app, $api_token);

        $dbh->do(
            'INSERT INTO activate_mid (mid, used_secret, api_app, api_token, created_at) VALUES(?, ?, ?, ?, ?)', undef,
            $mid, $used_secret, $api_app, $api_token, time()
        );

        send_text($mid, "Congratulation! Your '$api_app' app's api_token is '$api_token'.");
        return;
    }

    send_text($mid, 'Faild to registration.');
}

sub remove_activate_mid {
    my($activate_mid_id) = @_;
    $dbh->do('DELETE FROM activate_mid WHERE id=?', undef, $activate_mid_id);
}

sub get_callback_url {
    my($activate_mid_id) = @_;
    my $rows = $dbh->selectall_arrayref('SELECT * FROM callback_url WHERE activate_mid_id=?', { Slice => +{} }, $activate_mid_id);
    return $rows->[0];
}

sub save_callback_url {
    my($activate_mid_id, $url) = @_;
    remove_callback_url($activate_mid_id);
    $dbh->do('INSERT INTO callback_url (activate_mid_id, url, created_at) VALUES(?, ?, ?)', undef, $activate_mid_id, $url, time());
}

sub remove_callback_url {
    my($activate_mid_id) = @_;
    $dbh->do('DELETE FROM callback_url WHERE activate_mid_id=?', undef, $activate_mid_id);
}

sub send_text {
    my($mid, $text) = @_;

    my $json = +{
        to        => [ $mid ],
        toChannel => 1383378250,
        eventType => 138311608800106203,
        content   => +{
            contentType => 1,
            toType      => 1,
            text        => $text,
        },
    };

    my $res = $furl->post($line_bot_api_endpoint, [
        'Content-Type'                 => 'application/json; charset=UTF-8',
        'X-Line-ChannelID'             => $channel_id,
        'X-Line-ChannelSecret'         => $channel_secret,
        'X-Line-Trusted-User-With-ACL' => $bot_mid,
    ], encode_json($json));

    $res;
}

__END__

Usage
plackup --host $IP_ADDR -p $PORT lnyappo.pl 

Description
LINE BOT API Trial を利用してシンプルな Web API を利用し、このアプリで紐付けた LINE アカウントに API に送信されたメッセージを送信することができます。

ikachan for LINE 的なものです。

1. https://business.line.me/ で必要な情報を設定する
2. LNYAPPO_REGISTRATION_SECRET に、好きな文字列を指定する
3. LINE_* の必要な項目を LINE の開発サイトからコピペして設定する
4. このアプリを適当な場所で起動する
5. LINE の開発者サイトに、このアプリの endpoint url を設定する https://hostname:443/linebot/callback とか
6. 作成した Bot と友達登録をする
7. その Bot に向けて LNYAPPO_REGISTRATION_SECRET を prefix にして次の文字列を送る。
  例えば hello を設定してたら
  > hello add appname
  appname は、任意の名前で、 appname と api_token の組み合わせで alert 送信元の判別が可能。判別したくなければ1個だけ作れば良い。
8. Bot から設定された api_token が戻ってくるので、どこかで覚える
9. api_token と hello add で設定した appname を利用して、このアプリの API を叩けば LINE に任意のメッセージを送れます

Command reference
LNYAPPO_REGISTRATION_SECRET=hello の場合

1. app 登録
  > hello add appname

2. app 削除
  > hello del appname

3. app の callback url にメッセージを送る
  > hello send message_text

callback url 登録は、このアプリの web ui でできる。


for SQLite 
$ sqlite3 lnyappo.db
CREATE TABLE activate_mid (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  mid         TEXT NOT NULL UNIQUE,
  used_secret TEXT NOT NULL UNIQUE,
  api_app     TEXT NOT NULL,
  api_token   TEXT NOT NULL,
  created_at  INTEGER,
  UNIQUE(api_app, api_token)
);
CREATE INDEX activate_mid_mid       ON activate_mid(mid);
CREATE INDEX activate_mid_api_app_token ON activate_mid(api_app, api_token);

CREATE TABLE callback_url (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  activate_mid_id INTEGER NOT NULL UNIQUE,
  url             TEXT NOT NULL,
  created_at      INTEGER
);
CREATE INDEX callback_url_activate_mid_id ON callback_url(activate_mid_id);
