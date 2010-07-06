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
-- Name: keyword; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE keyword (
    id uuid NOT NULL,
    keyword character varying(100) NOT NULL
);


--
-- Name: twitter; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE twitter (
    twitter_id bigint NOT NULL,
    mention_at timestamp with time zone NOT NULL,
    mention_by character varying(100) NOT NULL,
    url_id uuid NOT NULL,
    keyword_id uuid
);


--
-- Name: url; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE url (
    id uuid NOT NULL,
    url character varying(2048) NOT NULL,
    verified_url_id uuid
);


--
-- Name: verified_url; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE verified_url (
    id uuid NOT NULL,
    url character varying(2048) NOT NULL,
    fetched_at timestamp(0) with time zone NOT NULL,
    response_code integer NOT NULL,
    title text,
    content_type character varying(50)
);


--
-- Name: keyword_keyword; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY keyword
    ADD CONSTRAINT keyword_keyword UNIQUE (keyword);


--
-- Name: keyword_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY keyword
    ADD CONSTRAINT keyword_pkey PRIMARY KEY (id);


--
-- Name: url_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY url
    ADD CONSTRAINT url_pkey PRIMARY KEY (id);


--
-- Name: verified_url_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY verified_url
    ADD CONSTRAINT verified_url_pkey PRIMARY KEY (id);


--
-- Name: verified_url_url; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY verified_url
    ADD CONSTRAINT verified_url_url UNIQUE (url);


--
-- Name: twitter_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX twitter_mention_at ON twitter USING btree (mention_at DESC);


--
-- Name: url_url; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX url_url ON url USING btree (url);


--
-- Name: url_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX url_verified_url_id ON url USING btree (verified_url_id);


--
-- Name: verified_url_fetched_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX verified_url_fetched_at ON verified_url USING btree (fetched_at NULLS FIRST);


--
-- Name: twitter_keyword_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY twitter
    ADD CONSTRAINT twitter_keyword_id FOREIGN KEY (keyword_id) REFERENCES keyword(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: twitter_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY twitter
    ADD CONSTRAINT twitter_url_id FOREIGN KEY (url_id) REFERENCES url(id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: url_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY url
    ADD CONSTRAINT url_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

