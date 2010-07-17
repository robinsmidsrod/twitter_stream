#!/usr/bin/env perl


use Mojolicious::Lite;
use DateTime ();

use lib 'lib';
use TwitterStream;

my $ts = TwitterStream->new();

my $allowed_precision = {
    'day'   => 1,
    'week'  => 1,
    'month' => 1,
    'year'  => 1,
};

get '/' => sub {
    my $self = shift;

    my $links = $ts->get_mentions({
        precision => 'day',
        limit     => 25,
        age       => 0,
    });

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => 'Most popular links today',
        layout   => 'default',
    );
};

get '/style.css' => 'stylesheet';

get '/keywords' => sub {
    my $self = shift;
    $self->render(
        template => 'keywords',
        keywords => scalar $ts->twitter_keywords,
        title    => 'Keywords being tracked',
        layout   => 'default',
    );
};

get '/:precision' => sub {
    my $self = shift;

    (my $precision) = grep { $allowed_precision->{$_} } $self->param('precision');
    unless ( $precision ) {
        $self->render_not_found();
        return;
    }

    my $links = $ts->get_mentions({
        precision => $precision,
        limit     => 25,
        age       => 0,
    });

    my $title = "Most popular links ";
    $title .= 'today'      if $precision eq 'day';
    $title .= 'this week'  if $precision eq 'week';
    $title .= 'this month' if $precision eq 'month';
    $title .= 'this year'  if $precision eq 'year';

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => $title,
        layout   => 'default',
    );
};

get '/:precision/:date' => sub {
    my $self = shift;

    (my $precision) = grep { $allowed_precision->{$_} } $self->param('precision');
    unless ( $precision ) {
        $self->render_not_found();
        return;
    }

    my $today = DateTime->today( time_zone => 'UTC' );
    my $age = DateTime::Duration->new( days => 0 );
    if ( $self->param('date') =~ m/^(\d+)$/ ) {
        $age = $1;
        $age = DateTime::Duration->new( "${precision}s" => $age );
    }

    if ( $self->param('date') =~ m/^(\d{4})-(\d{1,2})-(\d{1,2})$/ ) {
        my $year = $1;
        my $month = $2;
        my $day = $3;
        my $then = DateTime->new( year => $year, month => $month, day => $day, time_zone => 'UTC' );
        my $duration = $today->subtract_datetime( $then );
        $age = $duration->in_units('days') < 0 ? $age : $duration;
    }

    my $links = $ts->get_mentions({
        precision => $precision,
        limit     => 25,
        age       => $age->in_units("${precision}s"),
    });

    warn("Requested date: " . ( $today - $age ) . "\n");

    my $title = "Most popular links ";
    $title .= 'today'            if $precision eq 'day' and $age->in_units('days') == 0;
    $title .= 'yesterday'        if $precision eq 'day' and $age->in_units('days') == 1;
    $title .= $age->in_units('days') . ' days ago' if $precision eq 'day' and $age->in_units('days') > 1;

    $title .= 'this week'  if $precision eq 'week' and $age->in_units('weeks') == 0;
    $title .= 'last week'  if $precision eq 'week' and $age->in_units('weeks') == 1;
    $title .= $age->in_units('weeks') . ' weeks ago'  if $precision eq 'weeks' and $age->in_units('weeks') > 1;

    $title .= 'this month' if $precision eq 'month' and $age->in_units('months') == 0;
    $title .= 'last month' if $precision eq 'month' and $age->in_units('months') == 1;
    $title .= $age->in_units('months') . ' months ago' if $precision eq 'month' and $age->in_units('months') > 1;

    $title .= 'this year'  if $precision eq 'year' and $age->in_units('years') == 0;
    $title .= 'last year'  if $precision eq 'year' and $age->in_units('years') == 1;
    $title .= $age->in_units('years') . ' years ago'  if $precision eq 'year' and $age->in_units('years') > 1;

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => $title,
        layout   => 'default',
    );
};

get '/:precision/:date/:keyword' => sub {
    my $self = shift;
    $self->render(
        text => $self->param('precision') . $self->param('date') . $self->param('keyword'),
        layout => 'default',
    );
};

app->start;
__DATA__

@@ keywords.html.ep
<div class="keywords">
<h2>Keywords being tracked</h2>
<ul class="keywords">
% foreach my $keyword ( sort @$keywords ) {
<li class="keyword"><%= $keyword %></li>
% }
</ul>
</div>

@@ linklist.html.ep
<div class="links">
<ul class="links">
% foreach my $link ( @$links ) {
<li class="link">
<div class="mention_count">
<%= $link->{'mention_count'} %>
</div>
<div class="mention_title">
<a href="<%= $link->{'url'} %>"><%= $link->{'title'} || 'Unknown title (something of type ' . $link->{'content_type'} . ')' %></a>
</div>
<div class="mention_who">
First mentioned by <a href="<%= 'http://twitter.com/' . $link->{'first_mention_by_user'} . '/status/' . $link->{'first_mention_id'} %>"><%= $link->{'first_mention_by_name'} %></a> at <%= $link->{'first_mention_at'} %>
</div>
<div class="mention_url">
<a href="<%= $link->{'url'} %>"><%= $link->{'url'} %></a>
</div>
</li>
% }
</ul>
</div>
<%== include 'keywords' %>

@@ not_found.html.ep
% layout 'default', title => 'Not Found';
Not a valid page, please check the link for errors.

@@ layouts/default.html.ep
<!doctype html>
<html>
 <head>
  <title><%= $title %></title>
  <link rel="stylesheet" type="text/css" href="<%= url_for 'stylesheet' %>">
 </head>
 <body>
<h1><%== $title %></h1>
<%== content %>
 </body>
</html>

@@ stylesheet.css.ep
body { margin: 0 auto; max-width: 50em; font-family: sans-serif; line-height: 1.5em; }
ul.links { list-style-type: none; padding-left: 0; }
li.link { padding: 1em; margin-bottom: 0.5em; background: #eee; border-radius: 10px; -moz-border-radius: 10px; -webkit-border-radius: 10px; position: relative; }
div.mention_count { position: absolute; width: 2.5em; overflow: none; background-color: black; color: yellow; border-radius: 5px; -moz-border-radius: 5px; -webkit-border-radius: 5px; text-align: center; padding: 0.5em; font-size: 125%; }
div.mention_title { margin-left: 5em; }
div.mention_who   { margin-left: 5em; }
div.mention_url   { }
ul.keywords { display: inline; list-style-type: none; padding-left: 0; }
li.keyword { display: inline; margin-right: 0.075em; padding: 0.125em 1em; background-color: blue; color: yellow; border-radius: 5px; -moz-border-radius: 5px; -webkit-border-radius: 5px; }