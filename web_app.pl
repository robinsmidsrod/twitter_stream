#!/usr/bin/env perl

use Mojolicious::Lite;
use DateTime ();
use Encode ();
use utf8;

use lib 'lib';
use TwitterStream;

my $ts = TwitterStream->new();

# Set the Mojolicious session secret
app->secret( $ts->webapp_secret );
# Set default UTF8 charset for some types
app->types->type( html => 'text/html; charset=utf8' );
app->types->type( css  => 'text/css; charset=utf8' );
app->types->type( js   => 'text/javascript; charset=utf8' );

my $allowed_precision = {
    'day'   => 1,
    'week'  => 1,
    'month' => 1,
    'year'  => 1,
};

get '/' => sub {
    my $self = shift;

    my $precision = 'day',
    my $limit = calc_limit($self->param('limit'));
    my $offset = calc_offset($self->param('offset'));
    my $age = calc_age($precision);
    my $title = calc_title( $precision, $age );

    my $links = $ts->get_links({
        precision => $precision,
        limit     => $limit,
        offset    => $offset,
        age       => $age->in_units("${precision}s"),
    });

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => $title,
        precision => $precision,
        today     => today(),
        age       => $age,
        layout   => 'default',
    );
};

get '/(.precision)' => [ precision => qr/day|week|month|year/ ] => sub {
    my $self = shift;

    (my $precision) = grep { $allowed_precision->{$_} } $self->param('precision');
    unless ( $precision ) {
        $self->render_not_found();
        return;
    }

    my $limit = calc_limit($self->param('limit'));
    my $offset = calc_offset($self->param('offset'));
    my $age = calc_age( $precision );
    my $title = calc_title($precision, $age);

    my $links = $ts->get_links({
        precision => $precision,
        limit     => $limit,
        offset    => $offset,
        age       => $age->in_units("${precision}s"),
    });

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => $title,
        precision => $precision,
        today     => today(),
        age       => $age,
        layout   => 'default',
    );
};

get '/(.precision)/(.date)' => [ precision => qr/day|week|month|year/ ] => sub {
    my $self = shift;

    (my $precision) = grep { $allowed_precision->{$_} } $self->param('precision');
    unless ( $precision ) {
        $self->render_not_found();
        return;
    }

    my $age = calc_age( $precision, $self->param('date') );
    my $limit = calc_limit($self->param('limit'));
    my $offset = calc_offset($self->param('offset'));
    my $title = calc_title($precision, $age);

    my $links = $ts->get_links({
        precision => $precision,
        limit     => $limit,
        offset    => $offset,
        age       => $age->in_units("${precision}s"),
    });

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => $title,
        precision => $precision,
        today     => today(),
        age       => $age,
        layout   => 'default',
    );
};

get '/(.precision)/(.date)/(*keyword)' => [ precision => qr/day|week|month|year/ ] => sub {
    my $self = shift;

    (my $precision) = grep { $allowed_precision->{$_} } $self->param('precision');
    unless ( $precision ) {
        $self->render_not_found();
        return;
    }

    my $age = calc_age( $precision, $self->param('date') );
    my $keyword = $self->param('keyword') || "";
    my $limit = calc_limit($self->param('limit'));
    my $offset = calc_offset($self->param('offset'));
    my $title = calc_title($precision, $age, $keyword);

    my $links = $ts->get_links({
        precision => $precision,
        limit     => $limit,
        offset    => $offset,
        age       => $age->in_units("${precision}s"),
        keyword   => $keyword,
    });

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => $title,
        precision => $precision,
        today     => today(),
        age       => $age,
        layout   => 'default',
    );
};

get '/offtopic' => sub {
    my ($self) = @_;

    my $limit = calc_limit($self->param('limit'));
    my $offset = calc_offset($self->param('offset'));

    my $links = $ts->get_offtopic_links({
        limit     => $limit,
        offset    => $offset,
    });

    $self->render(
        template => 'linklist',
        links    => $links,
        keywords => scalar $ts->twitter_keywords,
        title    => 'Most recent off-topic links',
        layout   => 'default',
    );
};

get '/offtopic/(.id)' => sub {
    my ($self) = @_;

    my $link = $ts->get_link( $self->param('id') );
    unless ( ref($link) eq 'HASH' and keys %$link > 0 ) {
        $self->render_not_found();
        return;
    }

    $self->render(
        template => 'offtopic_link',
        link     => $link,
        title    => 'Is this link off-topic?',
        layout   => 'default',
    );
};

post '/offtopic/(.id)' => sub {
    my ($self) = @_;

    $ts->update_link_status(
        $self->param('id'),
        ( $self->param('decision') ? 1 : 0 ),
    );

    my $link = $ts->get_link( $self->param('id') );
    unless ( ref($link) eq 'HASH' and keys %$link > 0 ) {
        $self->render_not_found();
        return;
    }

    $self->render(
        template => 'offtopic_link',
        link     => $link,
        title    => 'Is this link off-topic?',
        layout   => 'default',
    );
};

get '/keywords' => sub {
    my $self = shift;
    $self->render(
        template => 'keywords',
        keywords => scalar $ts->twitter_keywords,
        title    => 'Keywords being tracked',
        layout   => 'default',
    );
};

get '/style.css' => 'style';

app->start;

################### helper functions ###########################

sub today {
    return scalar DateTime->today( time_zone => 'UTC' );
}

sub calc_age {
    my ($precision, $date) = @_;

    my $zero_duration = DateTime::Duration->new( days => 0 );
    return scalar $zero_duration unless $date;

    my $today = today();

    # String looks like an offset, just turn it into a duration object of the given precision
    if ( $date =~ m/^(\d+)$/ ) {
        my $age = $1;
        return scalar DateTime::Duration->new( "${precision}s" => $age );
    }

    # String looks like an ISO date, calculate difference between today and that
    if ( $date =~ m/^(\d{4})-(\d{1,2})-(\d{1,2})$/ ) {
        my $year = $1;
        my $month = $2;
        my $day = $3;
        my $then = DateTime->new( year => $year, month => $month, day => $day, time_zone => 'UTC' );
        my $duration = $today->subtract_datetime( $then );
        return scalar ( $duration->in_units('days') < 0 ? $zero_duration : $duration );
    }

    return scalar $zero_duration;
}

sub calc_title {
    my ($precision, $age, $keyword) = @_;

    my $title = "Most popular links ";

    if ( $keyword ) {
        $title = "Most popular links about '" . $keyword . "' ";
    }

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

    return $title;
}

sub calc_limit {
    my ($param) = @_;
    return $param ? ( int($param) || 25 ) : 25;
}

sub calc_offset {
    my ($param) = @_;
    return $param ? ( int($param) || 0 ) : 0;
}

__DATA__

@@ keywords.html.ep
% if ( exists stash->{'keywords'} ) {
<div class="keywords">
% unless ( $title eq 'Keywords being tracked' ) {
<h2>Keywords being tracked</h2>
% }
<ul class="keywords">
% foreach my $keyword ( sort @$keywords ) {
<li class="keyword"><%= $keyword %></li>
% }
</ul>
</div>
% }

@@ offtopic_link.html.ep
<form class="offtopic_question" action="/offtopic/<%= $link->{'id'} %>" method="post">
<div>
<button type="submit" name="decision" value="1">Yes</button>
<button type="submit" name="decision" value="0">No</button>
The link is currently tagged as <strong><%= $link->{'is_off_topic'} ? 'off-topic' : 'on-topic' %></strong>.
</div>
</form>
<div class="links">
<ul class="links">
<li class="link">
<%== include 'link' %>
</li>
</ul>
<iframe class="link" src="<%= $link->{'url'} %>" width="100%" height="500"></iframe>

@@ navigation.html.ep
% if ( exists stash->{'today'} and exists stash->{'precision'} ) {
<div class="nav">
<table summary="Navigation">
<tbody>
% foreach my $precision_type ( qw(day week month year) ) {
<tr>
<td><a href="/<%= $precision_type %>/"><%= $precision_type . " -1" %></a></td>
<td class="<%= $precision_type eq stash->{'precision'} ? 'highlight' : '' %>"><a href="/<%= $precision_type %>/"><%= $precision_type %></a></td>
<td><a href="/<%= $precision_type %>/"><%= $precision_type . " +1" %></a></td>
</tr>
% }
</tbody>
</table>
</div>
% }

@@ linklist.html.ep
<div class="links">
% if ( scalar @$links == 0 ) {
<span class="zero_records">No links found. Please try another time period.</span>
% }
<ul class="links">
% foreach my $link ( @$links ) {
<li class="link">
<%== include 'link', link => $link %>
</li>
% }
</ul>
</div>
<%== include 'keywords' %>

@@ link.html.ep
<div class="mention_count">
% if ( $link->{'mention_count'} ) {
<%= $link->{'mention_count'} %>
% }
% else {
N/A
% }
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
% if ( not exists $link->{'is_off_topic'} ) {
<div class="offtopic">
<a href="/offtopic/<%= $link->{'id'} %>">Off-topic?</a>
</div>
% }

@@ not_found.html.ep
% layout 'default', title => 'Not Found';
Not a valid page, please check the link for errors.

@@ layouts/default.html.ep
<!doctype html>
<html>
 <head>
  <title><%= $title %></title>
  <link rel="stylesheet" type="text/css" href="<%= url_for 'style' %>">
 </head>
 <body>
<h1><a href="/">Links mentioned on Twitter</a></h1>
<%== include 'navigation' %>
<h2><%== $title %></h2>
<%== content %>
 </body>
</html>

@@ style.css.ep
body { margin: 0 auto; max-width: 50em; font-family: sans-serif; line-height: 1.5em; }
a { text-decoration: none; }
ul.links { list-style-type: none; padding-left: 0; }
li.link { padding: 1em; margin-bottom: 0.5em; background: #eee; border-radius: 10px; -moz-border-radius: 10px; -webkit-border-radius: 10px; position: relative; }
div.mention_count { position: absolute; width: 2.5em; overflow: none; background-color: black; color: yellow; border-radius: 5px; -moz-border-radius: 5px; -webkit-border-radius: 5px; text-align: center; padding: 0.5em; font-size: 125%; }
div.mention_title { margin-left: 5em; font-weight: bold; }
div.mention_who   { margin-left: 5em; margin-right: 5.5em; }
div.mention_url   { margin-right: 5.5em; }
ul.keywords { display: inline; list-style-type: none; padding-left: 0; }
li.keyword { display: inline; margin-right: 0.075em; padding: 0.125em 1em; background-color: blue; color: yellow; border-radius: 5px; -moz-border-radius: 5px; -webkit-border-radius: 5px; }
form.offtopic_question button { font-size: 150%; }
form.offtopic_question strong { font-size: 125%; }
div.offtopic { position: absolute; right: 0.5em; bottom: 0.5em; overflow: none; background-color: #ddd; border-radius: 5px; -moz-border-radius: 5px; -webkit-border-radius: 5px; text-align: center; padding: 0.5em; }
div.offtopic a { font-weight: bold; }
div.nav { position: absolute; right: 0; top: 0; z-index: 1; margin: 0.5em; border: solid 1px black; border-radius: 5px; -moz-border-radius: 5px; -webkit-border-radius: 5px; background-color: #fafafa; }
span.zero_records { background: #f88; padding: 0.25em; border-radius: 5px; -moz-border-radius: 5px; -webkit-border-radius: 5px; }
td.highlight { font-weight: bold; }
