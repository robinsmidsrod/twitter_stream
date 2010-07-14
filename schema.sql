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
-- Name: mention; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention (
    id uuid NOT NULL,
    mention_at timestamp with time zone NOT NULL,
    url_id uuid NOT NULL,
    keyword_id uuid,
    verifier_process_id integer DEFAULT 0 NOT NULL
);


--
-- Name: mention_day; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_day (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: mention_day_keyword; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_day_keyword (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    keyword_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: mention_month; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_month (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: mention_month_keyword; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_month_keyword (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    keyword_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: mention_week; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_week (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: mention_week_keyword; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_week_keyword (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    keyword_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: mention_year; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_year (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: mention_year_keyword; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE mention_year_keyword (
    mention_at date NOT NULL,
    verified_url_id uuid NOT NULL,
    keyword_id uuid NOT NULL,
    mention_count integer DEFAULT 1 NOT NULL
);


--
-- Name: url; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE url (
    id uuid NOT NULL,
    url character varying(2048) NOT NULL,
    host character varying(100) NOT NULL,
    first_mention_id bigint NOT NULL,
    first_mention_at timestamp(0) with time zone NOT NULL,
    first_mention_by_name character varying(100) NOT NULL,
    first_mention_by_user character varying(100) NOT NULL,
    is_verified boolean DEFAULT false NOT NULL,
    verify_failed boolean DEFAULT false NOT NULL,
    verified_at timestamp(0) with time zone,
    verified_url_id uuid,
    verifier_process_id integer DEFAULT 0 NOT NULL
);


--
-- Name: verified_url; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE verified_url (
    id uuid NOT NULL,
    url character varying(2048) NOT NULL,
    verified_at timestamp(0) with time zone NOT NULL,
    content_type character varying(50) NOT NULL,
    title text,
    first_mention_id bigint NOT NULL,
    first_mention_at timestamp(0) with time zone NOT NULL,
    first_mention_by_name character varying(100) NOT NULL,
    first_mention_by_user character varying(100) NOT NULL
);


--
-- Name: keyword_pkey_id; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY keyword
    ADD CONSTRAINT keyword_pkey_id PRIMARY KEY (id);


--
-- Name: keyword_unique_keyword; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY keyword
    ADD CONSTRAINT keyword_unique_keyword UNIQUE (keyword);


--
-- Name: mention_day_keyword_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_day_keyword
    ADD CONSTRAINT mention_day_keyword_pkey PRIMARY KEY (mention_at, verified_url_id, keyword_id);


--
-- Name: mention_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_day
    ADD CONSTRAINT mention_day_pkey PRIMARY KEY (mention_at, verified_url_id);


--
-- Name: mention_month_keyword_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_month_keyword
    ADD CONSTRAINT mention_month_keyword_pkey PRIMARY KEY (mention_at, verified_url_id, keyword_id);


--
-- Name: mention_month_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_month
    ADD CONSTRAINT mention_month_pkey PRIMARY KEY (mention_at, verified_url_id);


--
-- Name: mention_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention
    ADD CONSTRAINT mention_pkey PRIMARY KEY (id);


--
-- Name: mention_week_keyword_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_week_keyword
    ADD CONSTRAINT mention_week_keyword_pkey PRIMARY KEY (mention_at, verified_url_id, keyword_id);


--
-- Name: mention_week_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_week
    ADD CONSTRAINT mention_week_pkey PRIMARY KEY (mention_at, verified_url_id);


--
-- Name: mention_year_keyword_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_year_keyword
    ADD CONSTRAINT mention_year_keyword_pkey PRIMARY KEY (mention_at, verified_url_id, keyword_id);


--
-- Name: mention_year_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY mention_year
    ADD CONSTRAINT mention_year_pkey PRIMARY KEY (mention_at, verified_url_id);


--
-- Name: url_pkey; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY url
    ADD CONSTRAINT url_pkey PRIMARY KEY (id);


--
-- Name: url_unique_url; Type: CONSTRAINT; Schema: public; Owner: -; Tablespace: 
--

ALTER TABLE ONLY url
    ADD CONSTRAINT url_unique_url UNIQUE (url);


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
-- Name: mention_day_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_day_idx_mention_at ON mention_day USING btree (mention_at);


--
-- Name: mention_day_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_day_idx_mention_count ON mention_day USING btree (mention_count);


--
-- Name: mention_day_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_day_idx_verified_url_id ON mention_day USING btree (verified_url_id);


--
-- Name: mention_day_keyword_idx_keyword_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_day_keyword_idx_keyword_id ON mention_day_keyword USING btree (keyword_id);


--
-- Name: mention_day_keyword_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_day_keyword_idx_mention_at ON mention_day_keyword USING btree (mention_at);


--
-- Name: mention_day_keyword_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_day_keyword_idx_mention_count ON mention_day_keyword USING btree (mention_count);


--
-- Name: mention_day_keyword_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_day_keyword_idx_verified_url_id ON mention_day_keyword USING btree (verified_url_id);


--
-- Name: mention_idx_keyword_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_idx_keyword_id ON mention USING btree (keyword_id);


--
-- Name: mention_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_idx_mention_at ON mention USING btree (mention_at DESC);


--
-- Name: mention_idx_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_idx_url_id ON mention USING btree (url_id);


--
-- Name: mention_idx_verifier_process_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_idx_verifier_process_id ON mention USING btree (verifier_process_id);


--
-- Name: mention_month_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_month_idx_mention_at ON mention_month USING btree (mention_at);


--
-- Name: mention_month_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_month_idx_mention_count ON mention_month USING btree (mention_count);


--
-- Name: mention_month_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_month_idx_verified_url_id ON mention_month USING btree (verified_url_id);


--
-- Name: mention_month_keyword_idx_keyword_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_month_keyword_idx_keyword_id ON mention_month_keyword USING btree (keyword_id);


--
-- Name: mention_month_keyword_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_month_keyword_idx_mention_at ON mention_month_keyword USING btree (mention_at);


--
-- Name: mention_month_keyword_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_month_keyword_idx_mention_count ON mention_month_keyword USING btree (mention_count);


--
-- Name: mention_month_keyword_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_month_keyword_idx_verified_url_id ON mention_month_keyword USING btree (verified_url_id);


--
-- Name: mention_week_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_week_idx_mention_at ON mention_week USING btree (mention_at);


--
-- Name: mention_week_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_week_idx_mention_count ON mention_week USING btree (mention_count);


--
-- Name: mention_week_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_week_idx_verified_url_id ON mention_week USING btree (verified_url_id);


--
-- Name: mention_week_keyword_idx_keyword_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_week_keyword_idx_keyword_id ON mention_week_keyword USING btree (keyword_id);


--
-- Name: mention_week_keyword_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_week_keyword_idx_mention_at ON mention_week_keyword USING btree (mention_at);


--
-- Name: mention_week_keyword_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_week_keyword_idx_mention_count ON mention_week_keyword USING btree (mention_count);


--
-- Name: mention_week_keyword_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_week_keyword_idx_verified_url_id ON mention_week_keyword USING btree (verified_url_id);


--
-- Name: mention_year_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_year_idx_mention_at ON mention_year USING btree (mention_at);


--
-- Name: mention_year_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_year_idx_mention_count ON mention_year USING btree (mention_count);


--
-- Name: mention_year_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_year_idx_verified_url_id ON mention_year USING btree (verified_url_id);


--
-- Name: mention_year_keyword_idx_keyword_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_year_keyword_idx_keyword_id ON mention_year_keyword USING btree (keyword_id);


--
-- Name: mention_year_keyword_idx_mention_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_year_keyword_idx_mention_at ON mention_year_keyword USING btree (mention_at);


--
-- Name: mention_year_keyword_idx_mention_count; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_year_keyword_idx_mention_count ON mention_year_keyword USING btree (mention_count);


--
-- Name: mention_year_keyword_idx_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX mention_year_keyword_idx_verified_url_id ON mention_year_keyword USING btree (verified_url_id);


--
-- Name: url_idx_verifier_process_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX url_idx_verifier_process_id ON url USING btree (verifier_process_id);


--
-- Name: url_verified_url_id; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX url_verified_url_id ON url USING btree (verified_url_id);


--
-- Name: verified_url_fetched_at; Type: INDEX; Schema: public; Owner: -; Tablespace: 
--

CREATE INDEX verified_url_fetched_at ON verified_url USING btree (verified_at NULLS FIRST);


--
-- Name: mention_day_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_day
    ADD CONSTRAINT mention_day_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_day_keyword_fk_keyword_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_day_keyword
    ADD CONSTRAINT mention_day_keyword_fk_keyword_id FOREIGN KEY (keyword_id) REFERENCES keyword(id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: mention_day_keyword_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_day_keyword
    ADD CONSTRAINT mention_day_keyword_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_fk_keyword_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention
    ADD CONSTRAINT mention_fk_keyword_id FOREIGN KEY (keyword_id) REFERENCES keyword(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_fk_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention
    ADD CONSTRAINT mention_fk_url_id FOREIGN KEY (url_id) REFERENCES url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_month_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_month
    ADD CONSTRAINT mention_month_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_month_keyword_fk_keyword_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_month_keyword
    ADD CONSTRAINT mention_month_keyword_fk_keyword_id FOREIGN KEY (keyword_id) REFERENCES keyword(id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: mention_month_keyword_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_month_keyword
    ADD CONSTRAINT mention_month_keyword_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_week_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_week
    ADD CONSTRAINT mention_week_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_week_keyword_fk_keyword_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_week_keyword
    ADD CONSTRAINT mention_week_keyword_fk_keyword_id FOREIGN KEY (keyword_id) REFERENCES keyword(id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: mention_week_keyword_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_week_keyword
    ADD CONSTRAINT mention_week_keyword_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_year_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_year
    ADD CONSTRAINT mention_year_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: mention_year_keyword_fk_keyword_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_year_keyword
    ADD CONSTRAINT mention_year_keyword_fk_keyword_id FOREIGN KEY (keyword_id) REFERENCES keyword(id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: mention_year_keyword_fk_verified_url_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY mention_year_keyword
    ADD CONSTRAINT mention_year_keyword_fk_verified_url_id FOREIGN KEY (verified_url_id) REFERENCES verified_url(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

