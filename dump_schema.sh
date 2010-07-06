#!/bin/sh

pg_dump -s -O -x twitter_stream >schema.sql

