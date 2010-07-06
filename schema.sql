--
-- PostgreSQL database dump
--

SET client_encoding = 'UTF8';
SET standard_conforming_strings = off;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET escape_string_warning = off;

SET search_path = public, pg_catalog;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: twitter; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE twitter (
    twitter_id bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by character varying(100) NOT NULL,
    keyword character varying(100) NOT NULL,
    url character varying(140) NOT NULL
);


--
-- Name: url; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE url (
    url character varying(140) NOT NULL,
    fetched_at timestamp(0) with time zone NOT NULL,
    response_code integer,
    real_url text,
    title text,
    content_type character varying(50)
);


--
-- Name: url_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY url
    ADD CONSTRAINT url_pkey PRIMARY KEY (url);


--
-- Name: twitter_created_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX twitter_created_at ON twitter USING btree (created_at);


--
-- Name: twitter_keyword; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX twitter_keyword ON twitter USING btree (keyword);


--
-- Name: twitter_url; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX twitter_url ON twitter USING btree (url);


--
-- PostgreSQL database dump complete
--

