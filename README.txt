# Work In Progress #

This is my idea:

I was planning on expanding the shortened URLs and doing a HTTP HEAD on each
url to pull out useful info, like mimetype, date and such - and if it is
HTML I would try to download a chunk of the start to get the
/html/head/title.

With that I can put the URLs (shortened and full) into a graph structure
with the hashtags and hopefully make a discovery website on top of it with
rss-feeds for hashtags.

An SVG/Flash/Raphaël graph traversal UI would be cool.

And then incrementing the URLs as more people mention them incrementing a
counter.

The data is not just from _my_ timeline - it's the firehose of twitter (if I
had full access, now it's just ~ 5% of tweets).

Imagine being able to take a bit.ly URL you get from somewhere, look it up
in a service like that, see what hashtags are related to it, then clicking
on a hashtag that you find interesting and then finding more interesting
links related to that hashtag.

Somewhat similar to pingwire.com, but for links.

I'd love to have the #perl or #modernperl RSS feed based on this somewhere.
