--
-- PostgreSQL database dump
--

-- baseline snapshot: taken from HEAD of current migration history (no releases are tagged yet)

-- Dumped from database version 16.16
-- Dumped by pg_dump version 16.16

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: cube; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS cube WITH SCHEMA public;


--
-- Name: earthdistance; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS earthdistance WITH SCHEMA public;


--
-- Name: subscription_tier; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.subscription_tier AS ENUM (
    'free',
    'starter',
    'professional',
    'enterprise',
    'custom'
);


--
-- Name: tenant_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.tenant_status AS ENUM (
    'active',
    'suspended',
    'pending',
    'cancelled',
    'trial'
);


--
-- Name: apply_events_partition_rls(regclass); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_events_partition_rls(target regclass) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', target);
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', target);
    EXECUTE format($policy$
        CREATE POLICY tenant_isolation ON %s
            USING (
                tenant_id IS NULL
                OR COALESCE(current_setting('app.current_tenant_id', TRUE), '') = ''
                OR tenant_id = current_setting('app.current_tenant_id', TRUE)
            )
            WITH CHECK (
                COALESCE(current_setting('app.current_tenant_id', TRUE), '') = ''
                OR tenant_id = current_setting('app.current_tenant_id', TRUE)
            )
    $policy$, target);
END;
$_$;


--
-- Name: archive_old_partitions(integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.archive_old_partitions(archive_after_months integer DEFAULT 12, dry_run boolean DEFAULT true) RETURNS TABLE(original_name text, archive_name text, action text)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    cutoff DATE;
    rec    RECORD;
    aname  TEXT;
BEGIN
    cutoff := (NOW() - (archive_after_months || ' months')::INTERVAL)::DATE;

    FOR rec IN
        SELECT c.relname::TEXT AS tname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class p ON p.oid = i.inhparent
        WHERE p.relname = 'events'
          AND c.relname ~ '^events_\d{4}_\d{2}$'
    LOOP
        -- Parse date from name
        IF TO_DATE(
            SUBSTRING(rec.tname FROM 'events_(\d{4}_\d{2})'),
            'YYYY_MM'
        ) < cutoff THEN
            aname := 'archive_' || rec.tname;
            IF dry_run THEN
                RETURN QUERY SELECT rec.tname::TEXT, aname::TEXT, 'dry_run'::TEXT;
            ELSE
                BEGIN
                    EXECUTE format('ALTER TABLE %I RENAME TO %I', rec.tname, aname);
                    RETURN QUERY SELECT rec.tname::TEXT, aname::TEXT, 'archived'::TEXT;
                EXCEPTION WHEN OTHERS THEN
                    RETURN QUERY SELECT rec.tname::TEXT, aname::TEXT,
                        format('error: %s', SQLERRM)::TEXT;
                END;
            END IF;
        END IF;
    END LOOP;
END;
$_$;


--
-- Name: auto_create_partitions(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auto_create_partitions(months_ahead integer DEFAULT 3) RETURNS TABLE(partition_name text, action text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    cur_date   DATE;
    target_dt  DATE;
    yr         INT;
    mo         INT;
    pname      TEXT;
    start_dt   DATE;
    end_dt     DATE;
BEGIN
    cur_date  := DATE_TRUNC('month', NOW())::DATE;
    target_dt := cur_date + (months_ahead || ' months')::INTERVAL;

    WHILE cur_date <= target_dt LOOP
        yr    := EXTRACT(YEAR  FROM cur_date)::INT;
        mo    := EXTRACT(MONTH FROM cur_date)::INT;
        pname := 'events_' || LPAD(yr::TEXT, 4, '0') || '_' || LPAD(mo::TEXT, 2, '0');
        start_dt := cur_date;
        end_dt   := cur_date + INTERVAL '1 month';

        -- Create partition (no-op if already exists)
        BEGIN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF events FOR VALUES FROM (%L) TO (%L)',
                pname, start_dt, end_dt
            );
            -- Issue #1344: new partitions inherit the tenant_isolation policy.
            PERFORM apply_events_partition_rls(pname::regclass);
            RETURN QUERY SELECT pname::TEXT, 'created'::TEXT;
        EXCEPTION WHEN duplicate_table THEN
            RETURN QUERY SELECT pname::TEXT, 'exists'::TEXT;
        END;

        cur_date := cur_date + INTERVAL '1 month';
    END LOOP;
END;
$$;


--
-- Name: cleanup_expired_audit_logs(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_expired_audit_logs() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    deleted_count bigint;
BEGIN
    DELETE FROM audit_logs WHERE expires_at IS NOT NULL AND expires_at < NOW();
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;


--
-- Name: cleanup_old_rate_limit_windows(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_old_rate_limit_windows() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM rate_limit_counters
    WHERE window_start < NOW() - INTERVAL '24 hours';
END;
$$;


--
-- Name: compute_audit_chain_hash(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.compute_audit_chain_hash(p_id uuid) RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT encode(
    sha256(
      (COALESCE(al.chain_hash, '') || '|' ||
       al.id::TEXT || '|' ||
       al.event_type || '|' ||
       al.action || '|' ||
       al.created_at::TEXT
      )::BYTEA
    ),
    'hex'
  )
  FROM audit_logs al
  WHERE al.id = p_id;
$$;


--
-- Name: detect_stale_statistics(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.detect_stale_statistics() RETURNS TABLE(table_name text, is_stale boolean, hours_since_analyze integer, staleness_threshold_hours integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        tsm.table_name,
        (EXTRACT(HOUR FROM (NOW() - tsm.last_analyzed)) > tsm.staleness_threshold_hours) AS is_stale,
        COALESCE(EXTRACT(HOUR FROM (NOW() - tsm.last_analyzed))::INT, 9999) AS hours_since_analyze,
        tsm.staleness_threshold_hours
    FROM table_statistics_metadata tsm
    ORDER BY hours_since_analyze DESC;
END;
$$;


--
-- Name: drop_old_partitions(integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.drop_old_partitions(retain_months integer DEFAULT 3, dry_run boolean DEFAULT false) RETURNS TABLE(partition_name text, dropped boolean, reason text)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    partition_record RECORD;
    cutoff_date TIMESTAMP;
    partition_count_dropped INT := 0;
    partition_count_checked INT := 0;
BEGIN
    -- Calculate cutoff date: today minus (retain_months * 30) days
    cutoff_date := CURRENT_DATE - (retain_months * INTERVAL '30 days');
    
    -- Iterate over all partitions of the events table
    FOR partition_record IN
        SELECT
            schemaname,
            tablename,
            -- Extract the partition date from the table name (e.g., events_2026_01 -> 2026-01-01)
            TO_DATE(
                RIGHT(tablename, 7) || '_01',
                'YYYY_MM_DD'
            ) AS partition_date
        FROM pg_tables
        WHERE schemaname = 'public'
          AND tablename ~ '^events_[0-9]{4}_[0-9]{2}$'
        ORDER BY tablename DESC
    LOOP
        partition_count_checked := partition_count_checked + 1;
        
        -- Check if this partition is older than the cutoff date
        IF partition_record.partition_date < cutoff_date THEN
            IF NOT dry_run THEN
                -- Execute the drop command
                EXECUTE format(
                    'DROP TABLE IF EXISTS %I.%I',
                    partition_record.schemaname,
                    partition_record.tablename
                );
                partition_count_dropped := partition_count_dropped + 1;
                RETURN QUERY SELECT
                    partition_record.tablename,
                    TRUE,
                    'Dropped (older than ' || retain_months || ' months)';
            ELSE
                -- In dry-run mode, just report what would be dropped
                RETURN QUERY SELECT
                    partition_record.tablename,
                    FALSE,
                    '[DRY RUN] Would drop (older than ' || retain_months || ' months)';
            END IF;
        ELSE
            RETURN QUERY SELECT
                partition_record.tablename,
                FALSE,
                'Retained (within ' || retain_months || ' month retention window)';
        END IF;
    END LOOP;
    
    -- Log summary to notice
    IF NOT dry_run THEN
        RAISE NOTICE 'Partition pruning completed: % partitions checked, % partitions dropped, cutoff date: %',
            partition_count_checked, partition_count_dropped, cutoff_date;
    ELSE
        RAISE NOTICE '[DRY RUN] Partition pruning simulation: % partitions checked, % would be dropped, cutoff date: %',
            partition_count_checked, partition_count_dropped, cutoff_date;
    END IF;
END;
$_$;


--
-- Name: extract_coordinates_from_event_data(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extract_coordinates_from_event_data() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Extract latitude and longitude from event_data if they exist
    IF NEW.event_data ? 'latitude' AND NEW.event_data ? 'longitude' THEN
        NEW.latitude := (NEW.event_data->>'latitude')::DOUBLE PRECISION;
        NEW.longitude := (NEW.event_data->>'longitude')::DOUBLE PRECISION;
    ELSIF NEW.event_data ? 'location' AND NEW.event_data->'location' ? 'lat' AND NEW.event_data->'location' ? 'lon' THEN
        NEW.latitude := (NEW.event_data->'location'->>'lat')::DOUBLE PRECISION;
        NEW.longitude := (NEW.event_data->'location'->>'lon')::DOUBLE PRECISION;
    ELSIF NEW.event_data ? 'coordinates' AND jsonb_array_length(NEW.event_data->'coordinates') >= 2 THEN
        NEW.longitude := (NEW.event_data->'coordinates'->0)::DOUBLE PRECISION;
        NEW.latitude := (NEW.event_data->'coordinates'->1)::DOUBLE PRECISION;
    END IF;
    
    RETURN NEW;
END;
$$;


--
-- Name: gdpr_get_subject_data(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gdpr_get_subject_data(p_email text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'email', p_email,
    'generated_at', NOW(),
    'subscriptions', (
      SELECT COALESCE(jsonb_agg(row_to_json(s)), '[]'::jsonb)
      FROM subscriptions s WHERE s.email_address = p_email
    ),
    'consent_records', (
      SELECT COALESCE(jsonb_agg(row_to_json(c)), '[]'::jsonb)
      FROM gdpr_consent_records c WHERE c.subject_email = p_email
    ),
    'data_subject_requests', (
      SELECT COALESCE(jsonb_agg(row_to_json(d)), '[]'::jsonb)
      FROM gdpr_data_subject_requests d WHERE d.subject_email = p_email
    )
  );
$$;


--
-- Name: get_partition_pruning_stats(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_partition_pruning_stats(from_ts timestamp with time zone, to_ts timestamp with time zone) RETURNS TABLE(partition_name text, partition_start timestamp with time zone, partition_end timestamp with time zone, would_be_accessed boolean, row_count bigint, size_bytes bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.relname::TEXT,
        -- Extract partition bounds from pg_get_expr
        to_timestamp(
            split_part(split_part(pg_get_expr(c.relpartbound, c.oid), '''', 2), '''', 1),
            'YYYY-MM-DD'
        ) AT TIME ZONE 'UTC',
        to_timestamp(
            split_part(split_part(pg_get_expr(c.relpartbound, c.oid), '''', 4), '''', 1),
            'YYYY-MM-DD'
        ) AT TIME ZONE 'UTC',
        (
            to_timestamp(split_part(split_part(pg_get_expr(c.relpartbound, c.oid), '''', 2), '''', 1), 'YYYY-MM-DD') AT TIME ZONE 'UTC' < to_ts
            AND
            to_timestamp(split_part(split_part(pg_get_expr(c.relpartbound, c.oid), '''', 4), '''', 1), 'YYYY-MM-DD') AT TIME ZONE 'UTC' > from_ts
        ),
        COALESCE(s.n_live_tup, 0)::BIGINT,
        pg_total_relation_size(c.oid)::BIGINT
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    JOIN pg_class p ON p.oid = i.inhparent
    LEFT JOIN pg_stat_user_tables s ON s.relname = c.relname
    WHERE p.relname = 'events'
    ORDER BY c.relname;
END;
$$;


--
-- Name: get_partition_size_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_partition_size_stats() RETURNS TABLE(partition_name text, row_count bigint, size_bytes bigint, size_mb numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.relname::TEXT,
        COALESCE(s.n_live_tup, 0)::BIGINT,
        pg_total_relation_size(c.oid)::BIGINT,
        ROUND(pg_total_relation_size(c.oid) / 1024.0 / 1024.0, 2)
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    JOIN pg_class p ON p.oid = i.inhparent
    LEFT JOIN pg_stat_user_tables s ON s.relname = c.relname
    WHERE p.relname = 'events'
    ORDER BY c.relname;
END;
$$;


--
-- Name: get_statistics_report(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_statistics_report() RETURNS TABLE(table_name text, last_analyzed timestamp with time zone, hours_since_analyze integer, is_stale boolean, row_count bigint, table_size_mb numeric, recent_jobs_count integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        tsm.table_name,
        tsm.last_analyzed,
        COALESCE(EXTRACT(HOUR FROM (NOW() - tsm.last_analyzed))::INT, 9999),
        tsm.is_stale,
        tsm.row_count,
        ROUND((pg_total_relation_size(format('%I', tsm.table_name))::NUMERIC / 1024 / 1024), 2),
        COUNT(sj.id)::INT
    FROM table_statistics_metadata tsm
    LEFT JOIN statistics_analysis_jobs sj ON tsm.table_name = sj.table_name
        AND sj.started_at > NOW() - INTERVAL '7 days'
    GROUP BY tsm.table_name, tsm.last_analyzed, tsm.is_stale, tsm.row_count
    ORDER BY tsm.last_analyzed ASC NULLS LAST;
END;
$$;


--
-- Name: increment_schema_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.increment_schema_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.version := OLD.version + 1;
    RETURN NEW;
END;
$$;


--
-- Name: initialize_statistics_tracking(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.initialize_statistics_tracking() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    current_table TEXT;
BEGIN
    FOR current_table IN
        SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    LOOP
        INSERT INTO table_statistics_metadata (table_name, last_analyzed, is_stale)
        VALUES (current_table, NOW(), FALSE)
        ON CONFLICT (table_name) DO NOTHING;
    END LOOP;

    RAISE NOTICE 'Statistics tracking initialized for all public tables';
END;
$$;


--
-- Name: mark_statistics_stale(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_statistics_stale() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE table_statistics_metadata
    SET is_stale = TRUE,
        updated_at = NOW()
    WHERE table_name = TG_TABLE_NAME::TEXT;
    RETURN NEW;
END;
$$;


--
-- Name: refresh_recent_ledger_index(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_recent_ledger_index(window_ledgers bigint DEFAULT 518400) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    threshold BIGINT;
BEGIN
    SELECT GREATEST(COALESCE(MAX(ledger), 0) - window_ledgers, 0)
      INTO threshold
      FROM events;

    -- Build the replacement first so readers always have an index to use,
    -- then swap names. Everything runs in the caller's transaction.
    DROP INDEX IF EXISTS idx_events_recent_ledger_id_new;
    EXECUTE format(
        'CREATE INDEX idx_events_recent_ledger_id_new ON events (ledger DESC, id DESC) WHERE ledger > %s',
        threshold
    );
    DROP INDEX IF EXISTS idx_events_recent_ledger_id;
    ALTER INDEX idx_events_recent_ledger_id_new RENAME TO idx_events_recent_ledger_id;
    EXECUTE format(
        'COMMENT ON INDEX idx_events_recent_ledger_id IS %L',
        'Recent ledger window (ledger > ' || threshold || '): GET /v1/events?from_ledger=..&to_ledger=.. ORDER BY ledger DESC, id DESC. '
        || 'Rebuilt by refresh_recent_ledger_index().'
    );

    RETURN threshold;
END;
$$;


--
-- Name: refresh_table_statistics(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_table_statistics(target_table text DEFAULT NULL::text) RETURNS TABLE(table_name text, status text, duration_seconds integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    duration_int INT;
    current_table TEXT;
    row_count_val BIGINT;
    table_cursor CURSOR FOR
        SELECT tablename FROM pg_tables WHERE schemaname = 'public'
        AND (target_table IS NULL OR tablename = target_table)
        ORDER BY tablename;
    job_id UUID;
BEGIN
    OPEN table_cursor;
    LOOP
        FETCH table_cursor INTO current_table;
        EXIT WHEN current_table IS NULL;

        start_time := CLOCK_TIMESTAMP();
        job_id := gen_random_uuid();

        -- Insert job record
        INSERT INTO statistics_analysis_jobs (id, table_name, started_at, status)
        VALUES (job_id, current_table, start_time, 'running');

        -- Execute ANALYZE
        BEGIN
            EXECUTE format('ANALYZE %I', current_table);

            end_time := CLOCK_TIMESTAMP();
            duration_int := EXTRACT(EPOCH FROM (end_time - start_time))::INT;

            -- Get current row count
            EXECUTE format('SELECT count(*) FROM %I', current_table) INTO row_count_val;

            -- Update job record with success
            UPDATE statistics_analysis_jobs
            SET completed_at = end_time,
                duration_seconds = duration_int,
                row_count_analyzed = row_count_val,
                status = 'success'
            WHERE id = job_id;

            -- Update statistics metadata
            INSERT INTO table_statistics_metadata (table_name, last_analyzed, row_count, is_stale)
            VALUES (current_table, end_time, row_count_val, FALSE)
            ON CONFLICT (table_name) DO UPDATE
            SET last_analyzed = end_time,
                row_count = row_count_val,
                is_stale = FALSE,
                updated_at = NOW();

            RETURN QUERY SELECT current_table::TEXT, 'success'::TEXT, duration_int;

        EXCEPTION WHEN OTHERS THEN
            end_time := CLOCK_TIMESTAMP();
            duration_int := EXTRACT(EPOCH FROM (end_time - start_time))::INT;

            -- Update job record with error
            UPDATE statistics_analysis_jobs
            SET completed_at = end_time,
                duration_seconds = duration_int,
                status = 'error',
                error_message = SQLERRM
            WHERE id = job_id;

            RETURN QUERY SELECT current_table::TEXT, format('error: %s', SQLERRM)::TEXT, duration_int;
        END;
    END LOOP;
    CLOSE table_cursor;
END;
$$;


--
-- Name: set_audit_log_retention(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_audit_log_retention() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.severity = 'CRITICAL' THEN
        NEW.expires_at := NOW() + INTERVAL '180 days';
    ELSIF NEW.severity = 'WARNING' THEN
        NEW.expires_at := NOW() + INTERVAL '90 days';
    ELSE
        NEW.expires_at := NOW() + INTERVAL '30 days';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: touch_tenant_quotas_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_tenant_quotas_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: aggregation_errors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.aggregation_errors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    rule_id uuid NOT NULL,
    window_start timestamp with time zone NOT NULL,
    window_end timestamp with time zone NOT NULL,
    error_message text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: aggregation_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.aggregation_results (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    rule_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    window_start timestamp with time zone NOT NULL,
    window_end timestamp with time zone NOT NULL,
    group_values jsonb,
    aggregated_data jsonb NOT NULL,
    event_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: aggregation_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.aggregation_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    window_type text DEFAULT 'tumbling'::text NOT NULL,
    window_size_secs integer NOT NULL,
    slide_interval_secs integer,
    fields jsonb NOT NULL,
    group_by jsonb,
    filter_condition text,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    aggregation_ops jsonb,
    batch_size integer DEFAULT 100 NOT NULL
);


--
-- Name: anomaly_alert_feedback; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anomaly_alert_feedback (
    id uuid NOT NULL,
    alert_id uuid NOT NULL,
    feedback text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT anomaly_alert_feedback_feedback_check CHECK ((feedback = ANY (ARRAY['true_positive'::text, 'false_positive'::text, 'missed'::text])))
);


--
-- Name: anomaly_alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anomaly_alerts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    event_id uuid,
    metric_name text NOT NULL,
    metric_value double precision NOT NULL,
    expected_range text,
    detection_method text DEFAULT 'zscore'::text NOT NULL,
    anomaly_score double precision NOT NULL,
    severity text DEFAULT 'medium'::text NOT NULL,
    alerting_enabled boolean DEFAULT true NOT NULL,
    acknowledged boolean DEFAULT false NOT NULL,
    acknowledged_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: anomaly_feedback; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anomaly_feedback (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    alert_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    is_true_positive boolean NOT NULL,
    feedback_note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: anomaly_training_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anomaly_training_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    metric_name text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    training_window_days integer DEFAULT 30 NOT NULL,
    samples_processed bigint DEFAULT 0 NOT NULL,
    error_message text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: anonymization_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anonymization_rules (
    id integer NOT NULL,
    name text NOT NULL,
    pattern text NOT NULL,
    replacement text DEFAULT '[REDACTED]'::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: anonymization_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.anonymization_rules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: anonymization_rules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.anonymization_rules_id_seq OWNED BY public.anonymization_rules.id;


--
-- Name: api_key_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_key_tenants (
    key_hash text NOT NULL,
    tenant_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    key_hash text NOT NULL,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    tenant_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    CONSTRAINT api_keys_key_hash_sha256 CHECK ((key_hash ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT api_keys_name_not_blank CHECK ((length(btrim(name)) > 0)),
    CONSTRAINT api_keys_scopes_known CHECK ((scopes <@ ARRAY['read:events'::text, 'write:subscriptions'::text, 'admin'::text]))
);


--
-- Name: api_request_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_request_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    endpoint character varying(500) NOT NULL,
    method character varying(10) NOT NULL,
    status_code integer,
    response_time_ms integer,
    "timestamp" timestamp with time zone DEFAULT now() NOT NULL,
    user_agent text,
    ip_address inet
);


--
-- Name: audit_log_exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log_exports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    exported_by text NOT NULL,
    export_format text DEFAULT 'json'::text NOT NULL,
    filter_params jsonb,
    row_count integer,
    file_hash text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_type text NOT NULL,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id text,
    resource_description text,
    request_path text,
    request_method text,
    query_params jsonb,
    api_key_hash text,
    user_email text,
    user_id text,
    ip_address inet,
    user_agent text,
    changes jsonb,
    old_value jsonb,
    new_value jsonb,
    status_code integer,
    success boolean DEFAULT true NOT NULL,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    severity text DEFAULT 'INFO'::text NOT NULL,
    expires_at timestamp with time zone,
    log_hash text,
    chain_hash text,
    signed_at timestamp with time zone,
    compliance_tags text[] DEFAULT '{}'::text[],
    retention_class text DEFAULT 'standard'::text,
    archived_at timestamp with time zone,
    export_ref text
);


--
-- Name: backfill_checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.backfill_checkpoints (
    range_start bigint NOT NULL,
    range_end bigint NOT NULL,
    next_ledger bigint NOT NULL,
    completed boolean DEFAULT false NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: baseline_statistics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.baseline_statistics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    metric_name text NOT NULL,
    mean double precision NOT NULL,
    std_dev double precision NOT NULL,
    min double precision NOT NULL,
    max double precision NOT NULL,
    median double precision NOT NULL,
    q1 double precision NOT NULL,
    q3 double precision NOT NULL,
    mad double precision NOT NULL,
    sample_count bigint DEFAULT 0 NOT NULL,
    training_window_days integer DEFAULT 30 NOT NULL,
    last_updated timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: batch_download_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_download_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    format text DEFAULT 'json'::text NOT NULL,
    filter_count integer DEFAULT 0 NOT NULL,
    event_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    error text
);


--
-- Name: cache_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cache_config (
    id text NOT NULL,
    tenant_id text NOT NULL,
    ttl_seconds integer DEFAULT 300 NOT NULL,
    max_size_mb integer DEFAULT 100 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    auto_warmup boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: cache_invalidation_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cache_invalidation_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    trigger_event text NOT NULL,
    affected_keys text[] NOT NULL,
    tenant_id text DEFAULT 'default'::text,
    reason text,
    triggered_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: compliance_report_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.compliance_report_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    report_type text NOT NULL,
    period_from timestamp with time zone NOT NULL,
    period_to timestamp with time zone NOT NULL,
    generated_by text,
    summary jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contract_abi_validation_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_abi_validation_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contract_id text NOT NULL,
    error text NOT NULL,
    logged_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contract_abis; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_abis (
    contract_id text NOT NULL,
    abi jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL,
    abi_hash text,
    is_valid boolean DEFAULT true NOT NULL,
    source text DEFAULT 'registered'::text NOT NULL,
    wasm_hash text
);


--
-- Name: contract_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_metadata (
    contract_id text NOT NULL,
    name text NOT NULL,
    description text,
    project_url text,
    source_repo text,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    verified boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contract_schema_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_schema_versions (
    contract_id text NOT NULL,
    version integer NOT NULL,
    schema jsonb NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contract_schemas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_schemas (
    contract_id text NOT NULL,
    schema jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    description text
);


--
-- Name: contract_spec_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_spec_attempts (
    contract_id text NOT NULL,
    status text NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contract_spec_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_spec_cache (
    wasm_hash text NOT NULL,
    spec jsonb NOT NULL,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contract_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_versions (
    id bigint NOT NULL,
    contract_id text NOT NULL,
    wasm_hash text NOT NULL,
    first_seen_ledger bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    is_upgrade boolean DEFAULT false NOT NULL
);


--
-- Name: contract_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_versions_id_seq OWNED BY public.contract_versions.id;


--
-- Name: contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contracts (
    contract_id text NOT NULL,
    deployer text,
    wasm_hash text,
    deployed_at timestamp with time zone,
    deployed_ledger bigint,
    deploy_tx_hash text,
    updated_at timestamp with time zone NOT NULL,
    updated_ledger bigint NOT NULL
);


--
-- Name: cross_chain_correlations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cross_chain_correlations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_event_id uuid NOT NULL,
    target_event_id uuid NOT NULL,
    source_network text NOT NULL,
    target_network text NOT NULL,
    causality text NOT NULL,
    confidence double precision NOT NULL,
    reason text NOT NULL,
    detected_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: cross_chain_event_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cross_chain_event_group_members (
    group_id uuid NOT NULL,
    event_id uuid NOT NULL
);


--
-- Name: cross_chain_event_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cross_chain_event_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    label text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: delivery_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_queue (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    event_id uuid NOT NULL,
    ledger bigint NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: derived_metric_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.derived_metric_snapshots (
    id bigint NOT NULL,
    metric_name text NOT NULL,
    labels jsonb DEFAULT '{}'::jsonb NOT NULL,
    value double precision NOT NULL,
    evaluated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: derived_metric_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.derived_metric_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: derived_metric_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.derived_metric_snapshots_id_seq OWNED BY public.derived_metric_snapshots.id;


--
-- Name: detected_patterns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.detected_patterns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pattern_type character varying(100) NOT NULL,
    confidence double precision NOT NULL,
    description text NOT NULL,
    affected_contracts text[] DEFAULT '{}'::text[] NOT NULL,
    frequency bigint NOT NULL,
    first_seen timestamp with time zone NOT NULL,
    last_seen timestamp with time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: discord_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.discord_integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    webhook_url text NOT NULL,
    bot_name character varying(255),
    avatar_url text,
    embed_enabled boolean DEFAULT true,
    thread_support boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: discord_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.discord_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    discord_integration_id uuid NOT NULL,
    event_id uuid,
    message_id text NOT NULL,
    channel_id text,
    thread_id text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: email_bounces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_bounces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    reason text,
    provider text,
    bounced_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_clicks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_clicks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    token text NOT NULL,
    email_notification_id uuid,
    recipient text NOT NULL,
    destination_url text NOT NULL,
    clicked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_notification_id uuid,
    recipient text NOT NULL,
    ab_template character(1),
    delivered_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_delivery_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_delivery_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid,
    email_address text NOT NULL,
    subject text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    error text,
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    idempotency_key text NOT NULL,
    recipient text NOT NULL,
    subject text NOT NULL,
    body text NOT NULL,
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_opens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_opens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    token text NOT NULL,
    email_notification_id uuid,
    recipient text NOT NULL,
    opened_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_send_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_send_counters (
    email_address text NOT NULL,
    date_utc date DEFAULT CURRENT_DATE NOT NULL,
    send_count integer DEFAULT 0 NOT NULL
);


--
-- Name: email_unsubscribes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_unsubscribes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    token text NOT NULL,
    unsubscribed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_addresses (
    event_id uuid NOT NULL,
    address text NOT NULL,
    "position" smallint NOT NULL,
    ledger bigint NOT NULL
);


--
-- Name: event_auto_tag_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_auto_tag_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tag_id uuid NOT NULL,
    event_type_match text,
    property_path text,
    property_value text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_tag_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_tag_assignments (
    event_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    source text DEFAULT 'manual'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_tags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    parent_id uuid,
    color text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_time_series_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_time_series_cache (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contract_id text,
    granularity text NOT NULL,
    bucket_start timestamp with time zone NOT NULL,
    bucket_end timestamp with time zone NOT NULL,
    event_count bigint DEFAULT 0 NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contract_id text NOT NULL,
    event_type text NOT NULL,
    tx_hash text NOT NULL,
    ledger bigint NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    event_data jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    schema_version integer DEFAULT 1 NOT NULL,
    event_data_normalized jsonb,
    schema_valid boolean,
    in_successful_call boolean DEFAULT true NOT NULL,
    ledger_hash text,
    event_data_decoded jsonb,
    topic_0_sym text GENERATED ALWAYS AS ((((event_data -> 'topic'::text) -> 0) ->> 'sym'::text)) STORED,
    anonymized boolean DEFAULT false NOT NULL,
    event_data_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, (event_data)::text)) STORED,
    tenant_id text,
    latitude double precision,
    longitude double precision,
    notified_at timestamp with time zone,
    fingerprint text,
    chain_id text DEFAULT 'mainnet'::text NOT NULL,
    event_data_compressed bytea,
    compression_algo text,
    network text DEFAULT 'soroban-mainnet'::text NOT NULL,
    tx_index integer,
    op_index integer,
    event_index integer,
    resource_fee bigint,
    cpu_insns bigint,
    mem_bytes bigint,
    asset_code text,
    asset_issuer text,
    sep41_event_type text,
    sep41_from text,
    sep41_to text,
    sep41_amount numeric(40,0),
    CONSTRAINT check_event_data_structure CHECK (((((event_data -> 'value'::text) IS NULL) OR (jsonb_typeof((event_data -> 'value'::text)) = 'object'::text)) AND (((event_data -> 'topic'::text) IS NULL) OR (jsonb_typeof((event_data -> 'topic'::text)) = 'array'::text)))),
    CONSTRAINT event_data_size_limit CHECK ((octet_length((event_data)::text) <= 65536))
);
ALTER TABLE ONLY public.events ALTER COLUMN event_data SET COMPRESSION lz4;


--
-- Name: events_contract_summary; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.events_contract_summary AS
 SELECT contract_id,
    count(*) AS event_count,
    max(ledger) AS latest_ledger
   FROM public.events
  GROUP BY contract_id
  WITH NO DATA;


--
-- Name: events_daily_summary; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.events_daily_summary AS
 SELECT date("timestamp") AS event_date,
    event_type,
    count(*) AS event_count
   FROM public.events
  GROUP BY (date("timestamp")), event_type
  WITH NO DATA;


--
-- Name: events_hourly_volume; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.events_hourly_volume AS
 SELECT date_trunc('hour'::text, "timestamp") AS event_hour,
    count(*) AS event_count
   FROM public.events
  WHERE ("timestamp" >= (now() - '7 days'::interval))
  GROUP BY (date_trunc('hour'::text, "timestamp"))
  WITH NO DATA;


--
-- Name: feature_flag_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feature_flag_audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    flag_id uuid NOT NULL,
    action text NOT NULL,
    reason text,
    triggered_by text DEFAULT 'system'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: feature_flags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feature_flags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    auto_rollback boolean DEFAULT true NOT NULL,
    rollback_threshold double precision DEFAULT 0.05 NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    rollout_percentage integer DEFAULT 100,
    target_contract_ids text[],
    target_user_ids text[],
    target_ips text[],
    target_regions text[]
);


--
-- Name: gdpr_breach_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gdpr_breach_notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    detected_at timestamp with time zone NOT NULL,
    notified_authority_at timestamp with time zone,
    notified_subjects_at timestamp with time zone,
    breach_type text NOT NULL,
    data_categories text[],
    affected_subject_count integer,
    description text NOT NULL,
    containment_measures text,
    likely_consequences text,
    dpa_reference text,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: gdpr_consent_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gdpr_consent_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subject_email text NOT NULL,
    consent_type text NOT NULL,
    granted boolean DEFAULT false NOT NULL,
    granted_at timestamp with time zone,
    withdrawn_at timestamp with time zone,
    ip_address inet,
    user_agent text,
    source text,
    legal_basis text,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: gdpr_data_subject_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gdpr_data_subject_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_type text NOT NULL,
    subject_email text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    requested_at timestamp with time zone DEFAULT now(),
    deadline_at timestamp with time zone DEFAULT (now() + '30 days'::interval) NOT NULL,
    completed_at timestamp with time zone,
    handled_by text,
    rejection_reason text,
    notes text,
    proof_of_completion jsonb
);


--
-- Name: github_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.github_integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    access_token text NOT NULL,
    owner character varying(255) NOT NULL,
    repository character varying(255) NOT NULL,
    issue_title_template text,
    issue_body_template text,
    auto_create_issues boolean DEFAULT true,
    pr_comment_enabled boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: github_issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.github_issues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    github_integration_id uuid NOT NULL,
    event_id uuid,
    issue_number integer NOT NULL,
    repository character varying(255) NOT NULL,
    owner character varying(255) NOT NULL,
    issue_url text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: group_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_metrics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    rule_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    group_key text NOT NULL,
    window_start timestamp with time zone NOT NULL,
    window_end timestamp with time zone NOT NULL,
    event_count bigint DEFAULT 0 NOT NULL,
    avg_value double precision,
    min_value double precision,
    max_value double precision,
    sum_value double precision,
    distinct_count bigint,
    extra_metrics jsonb,
    computed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: incidents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incidents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind text NOT NULL,
    severity text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    title text NOT NULL,
    signals jsonb DEFAULT '[]'::jsonb NOT NULL,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: indexer_bloom_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.indexer_bloom_state (
    id integer NOT NULL,
    capacity integer NOT NULL,
    fp_rate double precision NOT NULL,
    bitmap smallint[] NOT NULL,
    persisted_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: indexer_bloom_state_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.indexer_bloom_state_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: indexer_bloom_state_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.indexer_bloom_state_id_seq OWNED BY public.indexer_bloom_state.id;


--
-- Name: indexer_checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.indexer_checkpoints (
    id text DEFAULT 'singleton'::text NOT NULL,
    last_cursor text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: indexer_gaps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.indexer_gaps (
    id bigint NOT NULL,
    from_ledger bigint NOT NULL,
    to_ledger bigint NOT NULL,
    detected_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: indexer_gaps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.indexer_gaps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: indexer_gaps_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.indexer_gaps_id_seq OWNED BY public.indexer_gaps.id;


--
-- Name: indexer_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.indexer_state (
    id text DEFAULT 'singleton'::text NOT NULL,
    current_ledger bigint DEFAULT 0 NOT NULL,
    latest_ledger bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: intelligent_filters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intelligent_filters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    conditions jsonb NOT NULL,
    action jsonb NOT NULL,
    confidence double precision NOT NULL,
    auto_learned boolean DEFAULT false NOT NULL,
    true_positives bigint DEFAULT 0 NOT NULL,
    false_positives bigint DEFAULT 0 NOT NULL,
    true_negatives bigint DEFAULT 0 NOT NULL,
    false_negatives bigint DEFAULT 0 NOT NULL,
    "precision" double precision DEFAULT 0.0 NOT NULL,
    recall double precision DEFAULT 0.0 NOT NULL,
    f1_score double precision DEFAULT 0.0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ledger_hashes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_hashes (
    ledger bigint NOT NULL,
    hash text NOT NULL,
    prev_hash text,
    indexed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: maintenance_windows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.maintenance_windows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    contract_ids text[] DEFAULT '{}'::text[] NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_window_order CHECK ((end_time > start_time))
);


--
-- Name: metric_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.metric_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid,
    metric_name character varying(255) NOT NULL,
    metric_value double precision,
    "timestamp" timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id character varying(255)
);


--
-- Name: ml_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ml_models (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    model_type character varying(100) NOT NULL,
    version character varying(50) NOT NULL,
    accuracy double precision,
    "precision" double precision,
    recall double precision,
    f1_score double precision,
    training_samples bigint NOT NULL,
    last_trained_at timestamp with time zone NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    hyperparameters jsonb DEFAULT '{}'::jsonb NOT NULL,
    feature_importance jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ml_predictions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ml_predictions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    model_id uuid NOT NULL,
    prediction_type character varying(100) NOT NULL,
    predicted_value double precision NOT NULL,
    confidence_lower double precision NOT NULL,
    confidence_upper double precision NOT NULL,
    confidence_score double precision NOT NULL,
    feature_values jsonb NOT NULL,
    prediction_time timestamp with time zone DEFAULT now() NOT NULL,
    valid_until timestamp with time zone NOT NULL,
    actual_value double precision,
    error double precision
);


--
-- Name: mv_contract_event_counts; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.mv_contract_event_counts AS
 SELECT contract_id,
    event_type,
    date_trunc('day'::text, "timestamp") AS event_day,
    count(*) AS event_count,
    count(DISTINCT tx_hash) AS unique_tx_count,
    max("timestamp") AS last_event_at
   FROM public.events
  GROUP BY contract_id, event_type, (date_trunc('day'::text, "timestamp"))
  WITH NO DATA;


--
-- Name: mv_contract_resource_stats; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.mv_contract_resource_stats AS
 WITH tx AS (
         SELECT DISTINCT ON (events.contract_id, events.tx_hash) events.contract_id,
            events.tx_hash,
            events.ledger,
            events.resource_fee,
            events.cpu_insns,
            events.mem_bytes
           FROM public.events
          WHERE ((events.resource_fee IS NOT NULL) OR (events.cpu_insns IS NOT NULL) OR (events.mem_bytes IS NOT NULL))
          ORDER BY events.contract_id, events.tx_hash, events.ledger DESC
        )
 SELECT contract_id,
    count(*) AS tx_count,
    min(ledger) AS first_ledger,
    max(ledger) AS last_ledger,
    (sum(resource_fee))::bigint AS total_resource_fee,
    (avg(resource_fee))::double precision AS avg_resource_fee,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((resource_fee)::double precision)) AS p50_resource_fee,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((resource_fee)::double precision)) AS p95_resource_fee,
    max(resource_fee) AS max_resource_fee,
    (sum(cpu_insns))::bigint AS total_cpu_insns,
    (avg(cpu_insns))::double precision AS avg_cpu_insns,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((cpu_insns)::double precision)) AS p50_cpu_insns,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((cpu_insns)::double precision)) AS p95_cpu_insns,
    max(cpu_insns) AS max_cpu_insns,
    (sum(mem_bytes))::bigint AS total_mem_bytes,
    (avg(mem_bytes))::double precision AS avg_mem_bytes,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((mem_bytes)::double precision)) AS p50_mem_bytes,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((mem_bytes)::double precision)) AS p95_mem_bytes,
    max(mem_bytes) AS max_mem_bytes,
    now() AS refreshed_at
   FROM tx
  GROUP BY contract_id
  WITH NO DATA;


--
-- Name: tx_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tx_resources (
    tx_hash text NOT NULL,
    contract_id text NOT NULL,
    ledger bigint NOT NULL,
    resource_fee bigint DEFAULT 0 NOT NULL,
    instructions bigint DEFAULT 0 NOT NULL,
    read_bytes bigint DEFAULT 0 NOT NULL,
    write_bytes bigint DEFAULT 0 NOT NULL,
    closed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mv_contract_resources_daily; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.mv_contract_resources_daily AS
 SELECT contract_id,
    date_trunc('day'::text, closed_at) AS day,
    count(*) AS tx_count,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((resource_fee)::double precision)) AS fee_p50,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((resource_fee)::double precision)) AS fee_p95,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((instructions)::double precision)) AS instructions_p50,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((instructions)::double precision)) AS instructions_p95,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY (((read_bytes + write_bytes))::double precision)) AS io_bytes_p50,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY (((read_bytes + write_bytes))::double precision)) AS io_bytes_p95
   FROM public.tx_resources
  GROUP BY contract_id, (date_trunc('day'::text, closed_at))
  WITH NO DATA;


--
-- Name: mv_contract_summary; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.mv_contract_summary AS
 SELECT contract_id,
    count(*) AS event_count,
    max("timestamp") AS latest_event_timestamp,
    min("timestamp") AS first_event_timestamp,
    min(ledger) AS min_ledger,
    max(ledger) AS max_ledger,
    count(DISTINCT tx_hash) AS unique_tx_count,
    count(*) FILTER (WHERE (event_type = 'contract'::text)) AS contract_events,
    count(*) FILTER (WHERE (event_type = 'diagnostic'::text)) AS diagnostic_events,
    count(*) FILTER (WHERE (event_type = 'system'::text)) AS system_events
   FROM public.events
  GROUP BY contract_id
  WITH NO DATA;


--
-- Name: networks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.networks (
    chain_id text NOT NULL,
    display_name text NOT NULL,
    rpc_url text NOT NULL,
    passphrase text NOT NULL,
    is_enabled boolean DEFAULT true NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone,
    last_ledger bigint,
    health_status text DEFAULT 'unknown'::text NOT NULL
);


--
-- Name: normalization_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.normalization_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    contract_id text NOT NULL,
    pointer text NOT NULL,
    transform text NOT NULL,
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: notification_acknowledgments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_acknowledgments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel character varying(50) NOT NULL,
    event_contract_id character varying(100),
    event_type character varying(50),
    priority character varying(20) DEFAULT 'medium'::character varying NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    escalation_channel character varying(100),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    acknowledged_at timestamp with time zone,
    escalated_at timestamp with time zone
);


--
-- Name: notification_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_type text NOT NULL,
    recipient text NOT NULL,
    event_id text,
    triggered_at timestamp with time zone DEFAULT now() NOT NULL,
    delivered_at timestamp with time zone,
    status text DEFAULT 'pending'::text NOT NULL,
    error text,
    CONSTRAINT notification_audit_log_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'delivered'::text, 'failed'::text])))
);


--
-- Name: notification_channel_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_channel_group_members (
    group_id uuid NOT NULL,
    channel_id uuid NOT NULL
);


--
-- Name: notification_channel_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_channel_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: notification_channel_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_channel_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    version_number integer NOT NULL,
    name text NOT NULL,
    channel_type text NOT NULL,
    config jsonb NOT NULL,
    retry_policy jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: notification_channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    channel_type text NOT NULL,
    config jsonb NOT NULL,
    retry_policy jsonb DEFAULT '{"max_attempts": 3, "max_backoff_ms": 60000, "backoff_multiplier": 2.0, "initial_backoff_ms": 1000}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    content_filter jsonb,
    failover_channel_id uuid,
    cost_per_notification_cents integer DEFAULT 0 NOT NULL,
    description text,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    owner text,
    status text DEFAULT 'active'::text NOT NULL,
    contract_filter text[] DEFAULT '{}'::text[] NOT NULL,
    CONSTRAINT notification_channels_channel_type_check CHECK ((channel_type = ANY (ARRAY['webhook'::text, 'email'::text, 'sms'::text]))),
    CONSTRAINT notification_channels_status_check CHECK ((status = ANY (ARRAY['active'::text, 'inactive'::text, 'paused'::text])))
);


--
-- Name: notification_costs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_costs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    channel_name text NOT NULL,
    channel_type text NOT NULL,
    cost_cents integer DEFAULT 0 NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: notification_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_type text NOT NULL,
    channel_config_id uuid,
    event_id uuid,
    status text NOT NULL,
    delivered_at timestamp with time zone DEFAULT now() NOT NULL,
    error text,
    channel_metadata jsonb,
    retry_count integer DEFAULT 0 NOT NULL,
    latency_ms integer,
    CONSTRAINT notification_deliveries_status_check CHECK ((status = ANY (ARRAY['success'::text, 'failure'::text])))
);


--
-- Name: notification_delivery_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.notification_delivery_stats AS
 SELECT channel_type,
    status,
    count(*) AS count,
    avg(latency_ms) AS avg_latency_ms,
    max(delivered_at) AS last_delivery
   FROM public.notification_deliveries
  GROUP BY channel_type, status;


--
-- Name: notification_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    subject text NOT NULL,
    body text NOT NULL,
    is_active boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pagerduty_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pagerduty_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    routing_key text NOT NULL,
    service_name text DEFAULT 'Soroban Pulse'::text NOT NULL,
    contract_filter text[],
    event_type_filter text[],
    severity_mapping jsonb DEFAULT '{"system": "info", "contract": "error", "diagnostic": "warning"}'::jsonb NOT NULL,
    auto_resolve boolean DEFAULT true NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pagerduty_escalation_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pagerduty_escalation_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    integration_id uuid NOT NULL,
    policy_id text NOT NULL,
    policy_name text NOT NULL,
    policy_json jsonb,
    fetched_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: pagerduty_incidents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pagerduty_incidents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    integration_id uuid,
    dedup_key text NOT NULL,
    incident_key text,
    contract_id text NOT NULL,
    event_type text NOT NULL,
    status text DEFAULT 'triggered'::text NOT NULL,
    acknowledged_at timestamp with time zone,
    acknowledged_by text,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: pagerduty_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pagerduty_integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    routing_key text NOT NULL,
    service_name character varying(255) DEFAULT 'Soroban Pulse'::character varying NOT NULL,
    api_key text,
    escalation_policy_id text,
    contract_filter text[] DEFAULT '{}'::text[] NOT NULL,
    event_type_filter text[] DEFAULT '{}'::text[] NOT NULL,
    severity_mapping jsonb DEFAULT '{"system": "info", "contract": "error", "diagnostic": "warning"}'::jsonb NOT NULL,
    auto_resolve boolean DEFAULT true NOT NULL,
    auto_resolve_threshold_min integer DEFAULT 30 NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: partition_drops_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partition_drops_log (
    id bigint NOT NULL,
    dropped_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    partition_name text NOT NULL,
    retained_months integer NOT NULL,
    cutoff_date timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: partition_drops_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.partition_drops_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: partition_drops_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.partition_drops_log_id_seq OWNED BY public.partition_drops_log.id;


--
-- Name: pool_config_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pool_config_history (
    id bigint NOT NULL,
    config_version integer NOT NULL,
    config_variant text DEFAULT 'default'::text NOT NULL,
    config_json jsonb NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by text DEFAULT 'system'::text NOT NULL,
    rollback_of integer
);


--
-- Name: pool_config_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pool_config_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pool_config_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pool_config_history_id_seq OWNED BY public.pool_config_history.id;


--
-- Name: pool_tuning_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pool_tuning_snapshots (
    id bigint NOT NULL,
    recommended_min integer NOT NULL,
    recommended_max integer NOT NULL,
    avg_utilization double precision NOT NULL,
    scale_up_advised boolean DEFAULT false NOT NULL,
    scale_down_advised boolean DEFAULT false NOT NULL,
    config_version integer DEFAULT 1 NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pool_tuning_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pool_tuning_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pool_tuning_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pool_tuning_snapshots_id_seq OWNED BY public.pool_tuning_snapshots.id;


--
-- Name: push_delivery_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_delivery_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid,
    push_token text NOT NULL,
    device_type text,
    status text DEFAULT 'pending'::text NOT NULL,
    error text,
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: query_cache_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.query_cache_stats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cache_key text NOT NULL,
    query_type text NOT NULL,
    tenant_id text DEFAULT 'default'::text,
    hit_count bigint DEFAULT 0 NOT NULL,
    miss_count bigint DEFAULT 0 NOT NULL,
    last_hit timestamp with time zone,
    last_miss timestamp with time zone,
    entry_size_bytes bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: query_explain_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.query_explain_cache (
    id bigint NOT NULL,
    query_fingerprint text NOT NULL,
    sample_query text NOT NULL,
    explain_output jsonb NOT NULL,
    total_cost double precision,
    seq_scans text[],
    index_scans text[],
    warnings text[],
    recommendations text[],
    cached_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '01:00:00'::interval) NOT NULL
);


--
-- Name: query_explain_cache_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.query_explain_cache_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: query_explain_cache_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.query_explain_cache_id_seq OWNED BY public.query_explain_cache.id;


--
-- Name: rate_limit_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rate_limit_counters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    api_key_hash text NOT NULL,
    window_start timestamp with time zone NOT NULL,
    request_count integer DEFAULT 1 NOT NULL,
    last_updated timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: rate_limit_endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rate_limit_endpoints (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    endpoint_url text NOT NULL,
    per_minute_limit integer DEFAULT 60 NOT NULL,
    window_start timestamp with time zone DEFAULT now() NOT NULL,
    window_count integer DEFAULT 0 NOT NULL,
    consecutive_failures integer DEFAULT 0 NOT NULL,
    backoff_until timestamp with time zone,
    health_status text DEFAULT 'healthy'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rate_limit_endpoints_consecutive_failures_check CHECK ((consecutive_failures >= 0)),
    CONSTRAINT rate_limit_endpoints_health_status_check CHECK ((health_status = ANY (ARRAY['healthy'::text, 'degraded'::text, 'unhealthy'::text]))),
    CONSTRAINT rate_limit_endpoints_per_minute_limit_check CHECK ((per_minute_limit > 0)),
    CONSTRAINT rate_limit_endpoints_window_count_check CHECK ((window_count >= 0))
);


--
-- Name: replay_delivery_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.replay_delivery_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    replay_id uuid NOT NULL,
    event_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    error_message text,
    attempts integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    delivered_at timestamp with time zone
);


--
-- Name: replay_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.replay_schedules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    subscription_id uuid NOT NULL,
    schedule_type text DEFAULT 'interval'::text NOT NULL,
    cron_expression text,
    interval_secs bigint,
    filter_contract_id text,
    filter_event_type text,
    max_events bigint,
    replay_from_offset_secs bigint DEFAULT 3600 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_run_at timestamp with time zone,
    next_run_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: replay_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.replay_status (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    start_ledger bigint NOT NULL,
    end_ledger bigint NOT NULL,
    total_events bigint DEFAULT 0 NOT NULL,
    delivered_events bigint DEFAULT 0 NOT NULL,
    failed_events bigint DEFAULT 0 NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    error_message text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: saas_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saas_tenants (
    id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    organization_name character varying(255) NOT NULL,
    contact_email character varying(255) NOT NULL,
    subscription_tier public.subscription_tier DEFAULT 'free'::public.subscription_tier NOT NULL,
    status public.tenant_status DEFAULT 'pending'::public.tenant_status NOT NULL,
    trial_ends_at timestamp with time zone,
    subscription_started_at timestamp with time zone DEFAULT now() NOT NULL,
    subscription_renewed_at timestamp with time zone,
    custom_domain character varying(255),
    max_api_requests_per_day bigint DEFAULT 1000 NOT NULL,
    max_events_per_month bigint DEFAULT 10000 NOT NULL,
    max_subscriptions integer DEFAULT 5 NOT NULL,
    max_webhooks integer DEFAULT 2 NOT NULL,
    storage_quota_gb integer DEFAULT 1 NOT NULL,
    sla_uptime_percentage double precision DEFAULT 95.0 NOT NULL,
    dedicated_support boolean DEFAULT false NOT NULL,
    custom_branding boolean DEFAULT false NOT NULL,
    api_keys text[] DEFAULT '{}'::text[] NOT NULL,
    billing_email character varying(255),
    billing_id character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: saved_queries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saved_queries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    query_params jsonb NOT NULL,
    created_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_executed_at timestamp with time zone,
    execution_count bigint DEFAULT 0 NOT NULL
);


--
-- Name: scheduled_replay_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scheduled_replay_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    schedule_id uuid NOT NULL,
    replay_id uuid,
    status text DEFAULT 'running'::text NOT NULL,
    events_replayed bigint DEFAULT 0 NOT NULL,
    error_message text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone
);


--
-- Name: schema_validation_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_validation_metrics (
    contract_id text NOT NULL,
    pass_count bigint DEFAULT 0 NOT NULL,
    fail_count bigint DEFAULT 0 NOT NULL,
    last_checked timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: slack_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    webhook_url text,
    bot_token text,
    channel character varying(255) NOT NULL,
    app_id character varying(255),
    signing_secret text,
    block_kit_enabled boolean DEFAULT true,
    thread_support boolean DEFAULT false,
    user_mentions_enabled boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: slack_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slack_integration_id uuid NOT NULL,
    event_id uuid,
    message_ts text NOT NULL,
    channel_id text,
    thread_ts text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: slack_user_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_user_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slack_integration_id uuid NOT NULL,
    user_id character varying(255) NOT NULL,
    user_email character varying(255),
    subscribed_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: slow_query_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slow_query_log (
    id bigint NOT NULL,
    query_fingerprint text NOT NULL,
    sample_query text NOT NULL,
    avg_duration_ms double precision NOT NULL,
    max_duration_ms double precision NOT NULL,
    call_count bigint DEFAULT 1 NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: slow_query_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.slow_query_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: slow_query_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.slow_query_log_id_seq OWNED BY public.slow_query_log.id;


--
-- Name: sms_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sms_notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    phone_number text NOT NULL,
    message text NOT NULL,
    twilio_sid text,
    status text DEFAULT 'pending'::text NOT NULL,
    error_message text,
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: statistics_analysis_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.statistics_analysis_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    table_name text NOT NULL,
    started_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    duration_seconds integer,
    row_count_analyzed bigint,
    status text DEFAULT 'running'::text NOT NULL,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: subscription_pause_resume_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_pause_resume_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    action text NOT NULL,
    reason text,
    paused_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    callback_url text NOT NULL,
    from_ledger bigint NOT NULL,
    acked_ledger bigint DEFAULT 0 NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    subscription_type text DEFAULT 'single'::text NOT NULL,
    batch_size integer DEFAULT 10 NOT NULL,
    batch_timeout_ms integer DEFAULT 5000 NOT NULL,
    email_address text,
    email_enabled boolean DEFAULT false NOT NULL,
    push_token text,
    push_enabled boolean DEFAULT false NOT NULL,
    device_type text,
    webhook_template text,
    webhook_template_enabled boolean DEFAULT false NOT NULL,
    pause_until timestamp with time zone,
    pause_reason text,
    paused_at timestamp with time zone
);


--
-- Name: suppression_lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suppression_lists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    target text NOT NULL,
    target_type text NOT NULL,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    CONSTRAINT suppression_lists_target_type_check CHECK ((target_type = ANY (ARRAY['email'::text, 'webhook'::text])))
);


--
-- Name: table_statistics_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.table_statistics_metadata (
    table_name text NOT NULL,
    last_analyzed timestamp with time zone,
    last_vacuumed timestamp with time zone,
    row_count bigint,
    live_row_count bigint,
    dead_row_count bigint,
    table_size_bytes bigint,
    is_stale boolean DEFAULT true,
    staleness_threshold_hours integer DEFAULT 24,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: telegram_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    bot_token text NOT NULL,
    chat_id character varying(255) NOT NULL,
    webhook_enabled boolean DEFAULT false,
    webhook_url text,
    message_thread_support boolean DEFAULT false,
    button_support boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: telegram_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    telegram_integration_id uuid NOT NULL,
    event_id uuid,
    message_id character varying(255) NOT NULL,
    chat_id character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: telegram_user_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_user_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    telegram_integration_id uuid NOT NULL,
    user_id character varying(255) NOT NULL,
    username character varying(255),
    chat_id character varying(255) NOT NULL,
    subscribed_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: template_usage_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.template_usage_stats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    webhook_template_id uuid NOT NULL,
    total_transforms bigint DEFAULT 0 NOT NULL,
    successful bigint DEFAULT 0 NOT NULL,
    failed bigint DEFAULT 0 NOT NULL,
    last_used_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: template_validation_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.template_validation_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    webhook_template_id uuid,
    event_id uuid,
    error_message text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tenant_access_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_access_audit (
    id bigint NOT NULL,
    tenant_id text,
    api_key_hash text NOT NULL,
    http_method text NOT NULL,
    http_path text NOT NULL,
    query_string text,
    client_ip inet,
    response_status smallint NOT NULL,
    duration_us integer,
    trace_id text,
    accessed_at timestamp with time zone DEFAULT now() NOT NULL
)
PARTITION BY RANGE (accessed_at);


--
-- Name: tenant_access_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tenant_access_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tenant_access_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tenant_access_audit_id_seq OWNED BY public.tenant_access_audit.id;


--
-- Name: tenant_access_audit_2026_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_access_audit_2026_11 (
    id bigint DEFAULT nextval('public.tenant_access_audit_id_seq'::regclass) NOT NULL,
    tenant_id text,
    api_key_hash text NOT NULL,
    http_method text NOT NULL,
    http_path text NOT NULL,
    query_string text,
    client_ip inet,
    response_status smallint NOT NULL,
    duration_us integer,
    trace_id text,
    accessed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tenant_access_audit_2026_12; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_access_audit_2026_12 (
    id bigint DEFAULT nextval('public.tenant_access_audit_id_seq'::regclass) NOT NULL,
    tenant_id text,
    api_key_hash text NOT NULL,
    http_method text NOT NULL,
    http_path text NOT NULL,
    query_string text,
    client_ip inet,
    response_status smallint NOT NULL,
    duration_us integer,
    trace_id text,
    accessed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tenant_quotas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_quotas (
    tenant_id text NOT NULL,
    rate_limit_per_minute integer,
    rate_limit_per_hour integer,
    max_sse_connections integer,
    max_page_size integer,
    max_export_bytes_day bigint,
    suspended boolean DEFAULT false NOT NULL,
    suspended_reason text,
    suspended_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tenant_rls_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_rls_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    policy_json jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id text NOT NULL,
    name text NOT NULL,
    admin_email text,
    config jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    enabled boolean DEFAULT true NOT NULL
);


--
-- Name: token_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.token_transfers (
    event_id uuid NOT NULL,
    contract_id text NOT NULL,
    kind text NOT NULL,
    from_address text,
    to_address text,
    spender text,
    amount numeric(40,0),
    ledger bigint NOT NULL,
    tx_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: v_audit_retention_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_audit_retention_summary AS
 SELECT retention_class,
    severity,
    count(*) AS total_records,
    min(created_at) AS oldest_record,
    max(created_at) AS newest_record,
    count(*) FILTER (WHERE (expires_at < now())) AS expired_count,
    count(*) FILTER (WHERE (archived_at IS NOT NULL)) AS archived_count
   FROM public.audit_logs
  GROUP BY retention_class, severity
  ORDER BY retention_class, severity;


--
-- Name: v_partition_overview; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_partition_overview AS
 SELECT c.relname AS partition_name,
    pg_total_relation_size((c.oid)::regclass) AS size_bytes,
    round((((pg_total_relation_size((c.oid)::regclass))::numeric / 1024.0) / 1024.0), 2) AS size_mb,
    COALESCE(s.n_live_tup, (0)::bigint) AS live_rows,
    COALESCE(s.n_dead_tup, (0)::bigint) AS dead_rows,
    s.last_vacuum,
    s.last_autovacuum,
    s.last_analyze,
    s.last_autoanalyze,
    COALESCE(s.seq_scan, (0)::bigint) AS seq_scan_count,
    COALESCE(s.idx_scan, (0)::bigint) AS idx_scan_count
   FROM (((pg_inherits i
     JOIN pg_class c ON ((c.oid = i.inhrelid)))
     JOIN pg_class p ON ((p.oid = i.inhparent)))
     LEFT JOIN pg_stat_user_tables s ON ((s.relname = c.relname)))
  WHERE (p.relname = 'events'::name)
  ORDER BY c.relname;


--
-- Name: webhook_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    url text NOT NULL,
    secret text,
    notification_format text DEFAULT 'raw'::text NOT NULL,
    message_template text,
    contract_filter text[],
    event_type_filter text[],
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: webhook_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255),
    subscription_id uuid,
    webhook_url text NOT NULL,
    payload jsonb NOT NULL,
    status_code integer,
    success boolean DEFAULT false NOT NULL,
    attempts integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    delivered_at timestamp with time zone
);


--
-- Name: webhook_dlq; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_dlq (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    event_id uuid NOT NULL,
    payload jsonb NOT NULL,
    last_error text,
    failed_at timestamp with time zone DEFAULT now() NOT NULL,
    replayed_at timestamp with time zone
);


--
-- Name: webhook_failures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_failures (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    url text NOT NULL,
    payload jsonb NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    next_retry_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: webhook_log_access_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_log_access_audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    accessor text NOT NULL,
    action text NOT NULL,
    filter_summary text,
    result_count integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: webhook_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    url text NOT NULL,
    request_headers jsonb,
    request_body jsonb,
    request_truncated boolean DEFAULT false NOT NULL,
    response_status integer,
    response_body jsonb,
    response_truncated boolean DEFAULT false NOT NULL,
    duration_ms bigint,
    contract_id text,
    event_type text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: webhook_retry_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_retry_queue (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    url text NOT NULL,
    payload jsonb NOT NULL,
    secret_hash text,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 5 NOT NULL,
    next_retry_at timestamp with time zone DEFAULT now() NOT NULL,
    last_error text,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT webhook_retry_queue_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'processing'::text, 'succeeded'::text, 'failed'::text])))
);


--
-- Name: webhook_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    name text NOT NULL,
    template_content text NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tenant_access_audit_2026_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_access_audit ATTACH PARTITION public.tenant_access_audit_2026_11 FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');


--
-- Name: tenant_access_audit_2026_12; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_access_audit ATTACH PARTITION public.tenant_access_audit_2026_12 FOR VALUES FROM ('2026-12-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');


--
-- Name: anonymization_rules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymization_rules ALTER COLUMN id SET DEFAULT nextval('public.anonymization_rules_id_seq'::regclass);


--
-- Name: contract_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_versions ALTER COLUMN id SET DEFAULT nextval('public.contract_versions_id_seq'::regclass);


--
-- Name: derived_metric_snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.derived_metric_snapshots ALTER COLUMN id SET DEFAULT nextval('public.derived_metric_snapshots_id_seq'::regclass);


--
-- Name: indexer_bloom_state id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indexer_bloom_state ALTER COLUMN id SET DEFAULT nextval('public.indexer_bloom_state_id_seq'::regclass);


--
-- Name: indexer_gaps id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indexer_gaps ALTER COLUMN id SET DEFAULT nextval('public.indexer_gaps_id_seq'::regclass);


--
-- Name: partition_drops_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partition_drops_log ALTER COLUMN id SET DEFAULT nextval('public.partition_drops_log_id_seq'::regclass);


--
-- Name: pool_config_history id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pool_config_history ALTER COLUMN id SET DEFAULT nextval('public.pool_config_history_id_seq'::regclass);


--
-- Name: pool_tuning_snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pool_tuning_snapshots ALTER COLUMN id SET DEFAULT nextval('public.pool_tuning_snapshots_id_seq'::regclass);


--
-- Name: query_explain_cache id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.query_explain_cache ALTER COLUMN id SET DEFAULT nextval('public.query_explain_cache_id_seq'::regclass);


--
-- Name: slow_query_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slow_query_log ALTER COLUMN id SET DEFAULT nextval('public.slow_query_log_id_seq'::regclass);


--
-- Name: tenant_access_audit id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_access_audit ALTER COLUMN id SET DEFAULT nextval('public.tenant_access_audit_id_seq'::regclass);


--
-- Name: aggregation_errors aggregation_errors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aggregation_errors
    ADD CONSTRAINT aggregation_errors_pkey PRIMARY KEY (id);


--
-- Name: aggregation_results aggregation_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aggregation_results
    ADD CONSTRAINT aggregation_results_pkey PRIMARY KEY (id);


--
-- Name: aggregation_rules aggregation_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aggregation_rules
    ADD CONSTRAINT aggregation_rules_pkey PRIMARY KEY (id);


--
-- Name: anomaly_alert_feedback anomaly_alert_feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_alert_feedback
    ADD CONSTRAINT anomaly_alert_feedback_pkey PRIMARY KEY (id);


--
-- Name: anomaly_alerts anomaly_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_alerts
    ADD CONSTRAINT anomaly_alerts_pkey PRIMARY KEY (id);


--
-- Name: anomaly_feedback anomaly_feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_feedback
    ADD CONSTRAINT anomaly_feedback_pkey PRIMARY KEY (id);


--
-- Name: anomaly_training_jobs anomaly_training_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_training_jobs
    ADD CONSTRAINT anomaly_training_jobs_pkey PRIMARY KEY (id);


--
-- Name: anonymization_rules anonymization_rules_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymization_rules
    ADD CONSTRAINT anonymization_rules_name_key UNIQUE (name);


--
-- Name: anonymization_rules anonymization_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymization_rules
    ADD CONSTRAINT anonymization_rules_pkey PRIMARY KEY (id);


--
-- Name: api_key_tenants api_key_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_key_tenants
    ADD CONSTRAINT api_key_tenants_pkey PRIMARY KEY (key_hash);


--
-- Name: api_keys api_keys_key_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: api_request_logs api_request_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_request_logs
    ADD CONSTRAINT api_request_logs_pkey PRIMARY KEY (id);


--
-- Name: audit_log_exports audit_log_exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log_exports
    ADD CONSTRAINT audit_log_exports_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: backfill_checkpoints backfill_checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.backfill_checkpoints
    ADD CONSTRAINT backfill_checkpoints_pkey PRIMARY KEY (range_start, range_end);


--
-- Name: baseline_statistics baseline_statistics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.baseline_statistics
    ADD CONSTRAINT baseline_statistics_pkey PRIMARY KEY (id);


--
-- Name: baseline_statistics baseline_statistics_subscription_id_metric_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.baseline_statistics
    ADD CONSTRAINT baseline_statistics_subscription_id_metric_name_key UNIQUE (subscription_id, metric_name);


--
-- Name: batch_download_jobs batch_download_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_download_jobs
    ADD CONSTRAINT batch_download_jobs_pkey PRIMARY KEY (id);


--
-- Name: cache_config cache_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache_config
    ADD CONSTRAINT cache_config_pkey PRIMARY KEY (id);


--
-- Name: cache_config cache_config_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache_config
    ADD CONSTRAINT cache_config_tenant_id_key UNIQUE (tenant_id);


--
-- Name: cache_invalidation_log cache_invalidation_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache_invalidation_log
    ADD CONSTRAINT cache_invalidation_log_pkey PRIMARY KEY (id);


--
-- Name: compliance_report_runs compliance_report_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.compliance_report_runs
    ADD CONSTRAINT compliance_report_runs_pkey PRIMARY KEY (id);


--
-- Name: contract_abi_validation_log contract_abi_validation_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_abi_validation_log
    ADD CONSTRAINT contract_abi_validation_log_pkey PRIMARY KEY (id);


--
-- Name: contract_abis contract_abis_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_abis
    ADD CONSTRAINT contract_abis_pkey PRIMARY KEY (contract_id);


--
-- Name: contract_metadata contract_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_metadata
    ADD CONSTRAINT contract_metadata_pkey PRIMARY KEY (contract_id);


--
-- Name: contract_schema_versions contract_schema_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schema_versions
    ADD CONSTRAINT contract_schema_versions_pkey PRIMARY KEY (contract_id, version);


--
-- Name: contract_schemas contract_schemas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schemas
    ADD CONSTRAINT contract_schemas_pkey PRIMARY KEY (contract_id);


--
-- Name: contract_spec_attempts contract_spec_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_spec_attempts
    ADD CONSTRAINT contract_spec_attempts_pkey PRIMARY KEY (contract_id);


--
-- Name: contract_spec_cache contract_spec_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_spec_cache
    ADD CONSTRAINT contract_spec_cache_pkey PRIMARY KEY (wasm_hash);


--
-- Name: contract_versions contract_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_versions
    ADD CONSTRAINT contract_versions_pkey PRIMARY KEY (id);


--
-- Name: contracts contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_pkey PRIMARY KEY (contract_id);


--
-- Name: cross_chain_correlations cross_chain_correlations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_correlations
    ADD CONSTRAINT cross_chain_correlations_pkey PRIMARY KEY (id);


--
-- Name: cross_chain_correlations cross_chain_correlations_source_event_id_target_event_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_correlations
    ADD CONSTRAINT cross_chain_correlations_source_event_id_target_event_id_key UNIQUE (source_event_id, target_event_id);


--
-- Name: cross_chain_event_group_members cross_chain_event_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_event_group_members
    ADD CONSTRAINT cross_chain_event_group_members_pkey PRIMARY KEY (group_id, event_id);


--
-- Name: cross_chain_event_groups cross_chain_event_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_event_groups
    ADD CONSTRAINT cross_chain_event_groups_pkey PRIMARY KEY (id);


--
-- Name: delivery_queue delivery_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_queue
    ADD CONSTRAINT delivery_queue_pkey PRIMARY KEY (id);


--
-- Name: derived_metric_snapshots derived_metric_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.derived_metric_snapshots
    ADD CONSTRAINT derived_metric_snapshots_pkey PRIMARY KEY (id);


--
-- Name: detected_patterns detected_patterns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detected_patterns
    ADD CONSTRAINT detected_patterns_pkey PRIMARY KEY (id);


--
-- Name: discord_integrations discord_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discord_integrations
    ADD CONSTRAINT discord_integrations_pkey PRIMARY KEY (id);


--
-- Name: discord_integrations discord_integrations_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discord_integrations
    ADD CONSTRAINT discord_integrations_subscription_id_key UNIQUE (subscription_id);


--
-- Name: discord_integrations discord_integrations_webhook_url_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.discord_integrations
    ADD CONSTRAINT discord_integrations_webhook_url_encrypted CHECK ((webhook_url ~~ 'enc:v1:%'::text)) NOT VALID;


--
-- Name: discord_messages discord_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discord_messages
    ADD CONSTRAINT discord_messages_pkey PRIMARY KEY (id);


--
-- Name: email_bounces email_bounces_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_bounces
    ADD CONSTRAINT email_bounces_email_key UNIQUE (email);


--
-- Name: email_bounces email_bounces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_bounces
    ADD CONSTRAINT email_bounces_pkey PRIMARY KEY (id);


--
-- Name: email_clicks email_clicks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_clicks
    ADD CONSTRAINT email_clicks_pkey PRIMARY KEY (id);


--
-- Name: email_clicks email_clicks_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_clicks
    ADD CONSTRAINT email_clicks_token_key UNIQUE (token);


--
-- Name: email_deliveries email_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_deliveries
    ADD CONSTRAINT email_deliveries_pkey PRIMARY KEY (id);


--
-- Name: email_delivery_log email_delivery_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_log
    ADD CONSTRAINT email_delivery_log_pkey PRIMARY KEY (id);


--
-- Name: email_notifications email_notifications_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_notifications
    ADD CONSTRAINT email_notifications_idempotency_key_key UNIQUE (idempotency_key);


--
-- Name: email_notifications email_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_notifications
    ADD CONSTRAINT email_notifications_pkey PRIMARY KEY (id);


--
-- Name: email_opens email_opens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_opens
    ADD CONSTRAINT email_opens_pkey PRIMARY KEY (id);


--
-- Name: email_opens email_opens_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_opens
    ADD CONSTRAINT email_opens_token_key UNIQUE (token);


--
-- Name: email_send_counters email_send_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_send_counters
    ADD CONSTRAINT email_send_counters_pkey PRIMARY KEY (email_address, date_utc);


--
-- Name: email_unsubscribes email_unsubscribes_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_unsubscribes
    ADD CONSTRAINT email_unsubscribes_email_key UNIQUE (email);


--
-- Name: email_unsubscribes email_unsubscribes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_unsubscribes
    ADD CONSTRAINT email_unsubscribes_pkey PRIMARY KEY (id);


--
-- Name: email_unsubscribes email_unsubscribes_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_unsubscribes
    ADD CONSTRAINT email_unsubscribes_token_key UNIQUE (token);


--
-- Name: event_addresses event_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_addresses
    ADD CONSTRAINT event_addresses_pkey PRIMARY KEY (event_id, address, "position");


--
-- Name: event_auto_tag_rules event_auto_tag_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_auto_tag_rules
    ADD CONSTRAINT event_auto_tag_rules_pkey PRIMARY KEY (id);


--
-- Name: event_tag_assignments event_tag_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_tag_assignments
    ADD CONSTRAINT event_tag_assignments_pkey PRIMARY KEY (event_id, tag_id);


--
-- Name: event_tags event_tags_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_tags
    ADD CONSTRAINT event_tags_name_key UNIQUE (name);


--
-- Name: event_tags event_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_tags
    ADD CONSTRAINT event_tags_pkey PRIMARY KEY (id);


--
-- Name: event_time_series_cache event_time_series_cache_contract_id_granularity_bucket_star_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_time_series_cache
    ADD CONSTRAINT event_time_series_cache_contract_id_granularity_bucket_star_key UNIQUE (contract_id, granularity, bucket_start);


--
-- Name: event_time_series_cache event_time_series_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_time_series_cache
    ADD CONSTRAINT event_time_series_cache_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: feature_flag_audit feature_flag_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feature_flag_audit
    ADD CONSTRAINT feature_flag_audit_pkey PRIMARY KEY (id);


--
-- Name: feature_flags feature_flags_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feature_flags
    ADD CONSTRAINT feature_flags_name_key UNIQUE (name);


--
-- Name: feature_flags feature_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feature_flags
    ADD CONSTRAINT feature_flags_pkey PRIMARY KEY (id);


--
-- Name: gdpr_breach_notifications gdpr_breach_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gdpr_breach_notifications
    ADD CONSTRAINT gdpr_breach_notifications_pkey PRIMARY KEY (id);


--
-- Name: gdpr_consent_records gdpr_consent_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gdpr_consent_records
    ADD CONSTRAINT gdpr_consent_records_pkey PRIMARY KEY (id);


--
-- Name: gdpr_data_subject_requests gdpr_data_subject_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gdpr_data_subject_requests
    ADD CONSTRAINT gdpr_data_subject_requests_pkey PRIMARY KEY (id);


--
-- Name: github_integrations github_integrations_access_token_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.github_integrations
    ADD CONSTRAINT github_integrations_access_token_encrypted CHECK ((access_token ~~ 'enc:v1:%'::text)) NOT VALID;


--
-- Name: github_integrations github_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_integrations
    ADD CONSTRAINT github_integrations_pkey PRIMARY KEY (id);


--
-- Name: github_integrations github_integrations_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_integrations
    ADD CONSTRAINT github_integrations_subscription_id_key UNIQUE (subscription_id);


--
-- Name: github_issues github_issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_issues
    ADD CONSTRAINT github_issues_pkey PRIMARY KEY (id);


--
-- Name: group_metrics group_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_metrics
    ADD CONSTRAINT group_metrics_pkey PRIMARY KEY (id);


--
-- Name: incidents incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_pkey PRIMARY KEY (id);


--
-- Name: indexer_bloom_state indexer_bloom_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indexer_bloom_state
    ADD CONSTRAINT indexer_bloom_state_pkey PRIMARY KEY (id);


--
-- Name: indexer_checkpoints indexer_checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indexer_checkpoints
    ADD CONSTRAINT indexer_checkpoints_pkey PRIMARY KEY (id);


--
-- Name: indexer_gaps indexer_gaps_from_ledger_to_ledger_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indexer_gaps
    ADD CONSTRAINT indexer_gaps_from_ledger_to_ledger_key UNIQUE (from_ledger, to_ledger);


--
-- Name: indexer_gaps indexer_gaps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indexer_gaps
    ADD CONSTRAINT indexer_gaps_pkey PRIMARY KEY (id);


--
-- Name: indexer_state indexer_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indexer_state
    ADD CONSTRAINT indexer_state_pkey PRIMARY KEY (id);


--
-- Name: intelligent_filters intelligent_filters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intelligent_filters
    ADD CONSTRAINT intelligent_filters_pkey PRIMARY KEY (id);


--
-- Name: ledger_hashes ledger_hashes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_hashes
    ADD CONSTRAINT ledger_hashes_pkey PRIMARY KEY (ledger);


--
-- Name: maintenance_windows maintenance_windows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.maintenance_windows
    ADD CONSTRAINT maintenance_windows_pkey PRIMARY KEY (id);


--
-- Name: metric_history metric_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metric_history
    ADD CONSTRAINT metric_history_pkey PRIMARY KEY (id);


--
-- Name: ml_models ml_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ml_models
    ADD CONSTRAINT ml_models_pkey PRIMARY KEY (id);


--
-- Name: ml_predictions ml_predictions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ml_predictions
    ADD CONSTRAINT ml_predictions_pkey PRIMARY KEY (id);


--
-- Name: networks networks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.networks
    ADD CONSTRAINT networks_pkey PRIMARY KEY (chain_id);


--
-- Name: normalization_rules normalization_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.normalization_rules
    ADD CONSTRAINT normalization_rules_pkey PRIMARY KEY (id);


--
-- Name: notification_acknowledgments notification_acknowledgments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_acknowledgments
    ADD CONSTRAINT notification_acknowledgments_pkey PRIMARY KEY (id);


--
-- Name: notification_audit_log notification_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_audit_log
    ADD CONSTRAINT notification_audit_log_pkey PRIMARY KEY (id);


--
-- Name: notification_channel_group_members notification_channel_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_group_members
    ADD CONSTRAINT notification_channel_group_members_pkey PRIMARY KEY (group_id, channel_id);


--
-- Name: notification_channel_groups notification_channel_groups_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_groups
    ADD CONSTRAINT notification_channel_groups_name_key UNIQUE (name);


--
-- Name: notification_channel_groups notification_channel_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_groups
    ADD CONSTRAINT notification_channel_groups_pkey PRIMARY KEY (id);


--
-- Name: notification_channel_versions notification_channel_versions_channel_id_version_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_versions
    ADD CONSTRAINT notification_channel_versions_channel_id_version_number_key UNIQUE (channel_id, version_number);


--
-- Name: notification_channel_versions notification_channel_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_versions
    ADD CONSTRAINT notification_channel_versions_pkey PRIMARY KEY (id);


--
-- Name: notification_channels notification_channels_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channels
    ADD CONSTRAINT notification_channels_name_key UNIQUE (name);


--
-- Name: notification_channels notification_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channels
    ADD CONSTRAINT notification_channels_pkey PRIMARY KEY (id);


--
-- Name: notification_costs notification_costs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_costs
    ADD CONSTRAINT notification_costs_pkey PRIMARY KEY (id);


--
-- Name: notification_deliveries notification_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_deliveries
    ADD CONSTRAINT notification_deliveries_pkey PRIMARY KEY (id);


--
-- Name: notification_templates notification_templates_name_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_templates
    ADD CONSTRAINT notification_templates_name_version_key UNIQUE (name, version);


--
-- Name: notification_templates notification_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_templates
    ADD CONSTRAINT notification_templates_pkey PRIMARY KEY (id);


--
-- Name: pagerduty_configs pagerduty_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_configs
    ADD CONSTRAINT pagerduty_configs_pkey PRIMARY KEY (id);


--
-- Name: pagerduty_escalation_policies pagerduty_escalation_policies_integration_id_policy_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_escalation_policies
    ADD CONSTRAINT pagerduty_escalation_policies_integration_id_policy_id_key UNIQUE (integration_id, policy_id);


--
-- Name: pagerduty_escalation_policies pagerduty_escalation_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_escalation_policies
    ADD CONSTRAINT pagerduty_escalation_policies_pkey PRIMARY KEY (id);


--
-- Name: pagerduty_incidents pagerduty_incidents_dedup_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_incidents
    ADD CONSTRAINT pagerduty_incidents_dedup_key_key UNIQUE (dedup_key);


--
-- Name: pagerduty_incidents pagerduty_incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_incidents
    ADD CONSTRAINT pagerduty_incidents_pkey PRIMARY KEY (id);


--
-- Name: pagerduty_integrations pagerduty_integrations_api_key_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.pagerduty_integrations
    ADD CONSTRAINT pagerduty_integrations_api_key_encrypted CHECK (((api_key IS NULL) OR (api_key ~~ 'enc:v1:%'::text))) NOT VALID;


--
-- Name: pagerduty_integrations pagerduty_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_integrations
    ADD CONSTRAINT pagerduty_integrations_pkey PRIMARY KEY (id);


--
-- Name: pagerduty_integrations pagerduty_integrations_routing_key_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.pagerduty_integrations
    ADD CONSTRAINT pagerduty_integrations_routing_key_encrypted CHECK ((routing_key ~~ 'enc:v1:%'::text)) NOT VALID;


--
-- Name: pagerduty_integrations pagerduty_integrations_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_integrations
    ADD CONSTRAINT pagerduty_integrations_subscription_id_key UNIQUE (subscription_id);


--
-- Name: partition_drops_log partition_drops_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partition_drops_log
    ADD CONSTRAINT partition_drops_log_pkey PRIMARY KEY (id);


--
-- Name: pool_config_history pool_config_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pool_config_history
    ADD CONSTRAINT pool_config_history_pkey PRIMARY KEY (id);


--
-- Name: pool_tuning_snapshots pool_tuning_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pool_tuning_snapshots
    ADD CONSTRAINT pool_tuning_snapshots_pkey PRIMARY KEY (id);


--
-- Name: push_delivery_log push_delivery_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_delivery_log
    ADD CONSTRAINT push_delivery_log_pkey PRIMARY KEY (id);


--
-- Name: query_cache_stats query_cache_stats_cache_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.query_cache_stats
    ADD CONSTRAINT query_cache_stats_cache_key_key UNIQUE (cache_key);


--
-- Name: query_cache_stats query_cache_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.query_cache_stats
    ADD CONSTRAINT query_cache_stats_pkey PRIMARY KEY (id);


--
-- Name: query_explain_cache query_explain_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.query_explain_cache
    ADD CONSTRAINT query_explain_cache_pkey PRIMARY KEY (id);


--
-- Name: query_explain_cache query_explain_cache_query_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.query_explain_cache
    ADD CONSTRAINT query_explain_cache_query_fingerprint_key UNIQUE (query_fingerprint);


--
-- Name: rate_limit_counters rate_limit_counters_api_key_hash_window_start_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_limit_counters
    ADD CONSTRAINT rate_limit_counters_api_key_hash_window_start_key UNIQUE (api_key_hash, window_start);


--
-- Name: rate_limit_counters rate_limit_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_limit_counters
    ADD CONSTRAINT rate_limit_counters_pkey PRIMARY KEY (id);


--
-- Name: rate_limit_endpoints rate_limit_endpoints_endpoint_url_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_limit_endpoints
    ADD CONSTRAINT rate_limit_endpoints_endpoint_url_key UNIQUE (endpoint_url);


--
-- Name: rate_limit_endpoints rate_limit_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_limit_endpoints
    ADD CONSTRAINT rate_limit_endpoints_pkey PRIMARY KEY (id);


--
-- Name: replay_delivery_log replay_delivery_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replay_delivery_log
    ADD CONSTRAINT replay_delivery_log_pkey PRIMARY KEY (id);


--
-- Name: replay_schedules replay_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replay_schedules
    ADD CONSTRAINT replay_schedules_pkey PRIMARY KEY (id);


--
-- Name: replay_status replay_status_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replay_status
    ADD CONSTRAINT replay_status_pkey PRIMARY KEY (id);


--
-- Name: saas_tenants saas_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saas_tenants
    ADD CONSTRAINT saas_tenants_pkey PRIMARY KEY (id);


--
-- Name: saas_tenants saas_tenants_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saas_tenants
    ADD CONSTRAINT saas_tenants_tenant_id_key UNIQUE (tenant_id);


--
-- Name: saved_queries saved_queries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_queries
    ADD CONSTRAINT saved_queries_pkey PRIMARY KEY (id);


--
-- Name: scheduled_replay_runs scheduled_replay_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_replay_runs
    ADD CONSTRAINT scheduled_replay_runs_pkey PRIMARY KEY (id);


--
-- Name: schema_validation_metrics schema_validation_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_validation_metrics
    ADD CONSTRAINT schema_validation_metrics_pkey PRIMARY KEY (contract_id);


--
-- Name: slack_integrations slack_integrations_bot_token_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.slack_integrations
    ADD CONSTRAINT slack_integrations_bot_token_encrypted CHECK (((bot_token IS NULL) OR (bot_token ~~ 'enc:v1:%'::text))) NOT VALID;


--
-- Name: slack_integrations slack_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_integrations
    ADD CONSTRAINT slack_integrations_pkey PRIMARY KEY (id);


--
-- Name: slack_integrations slack_integrations_signing_secret_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.slack_integrations
    ADD CONSTRAINT slack_integrations_signing_secret_encrypted CHECK (((signing_secret IS NULL) OR (signing_secret ~~ 'enc:v1:%'::text))) NOT VALID;


--
-- Name: slack_integrations slack_integrations_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_integrations
    ADD CONSTRAINT slack_integrations_subscription_id_key UNIQUE (subscription_id);


--
-- Name: slack_integrations slack_integrations_webhook_url_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.slack_integrations
    ADD CONSTRAINT slack_integrations_webhook_url_encrypted CHECK (((webhook_url IS NULL) OR (webhook_url ~~ 'enc:v1:%'::text))) NOT VALID;


--
-- Name: slack_messages slack_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_messages
    ADD CONSTRAINT slack_messages_pkey PRIMARY KEY (id);


--
-- Name: slack_user_subscriptions slack_user_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_user_subscriptions
    ADD CONSTRAINT slack_user_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: slack_user_subscriptions slack_user_subscriptions_slack_integration_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_user_subscriptions
    ADD CONSTRAINT slack_user_subscriptions_slack_integration_id_user_id_key UNIQUE (slack_integration_id, user_id);


--
-- Name: slow_query_log slow_query_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slow_query_log
    ADD CONSTRAINT slow_query_log_pkey PRIMARY KEY (id);


--
-- Name: sms_notifications sms_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sms_notifications
    ADD CONSTRAINT sms_notifications_pkey PRIMARY KEY (id);


--
-- Name: statistics_analysis_jobs statistics_analysis_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.statistics_analysis_jobs
    ADD CONSTRAINT statistics_analysis_jobs_pkey PRIMARY KEY (id);


--
-- Name: subscription_pause_resume_log subscription_pause_resume_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_pause_resume_log
    ADD CONSTRAINT subscription_pause_resume_log_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: suppression_lists suppression_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppression_lists
    ADD CONSTRAINT suppression_lists_pkey PRIMARY KEY (id);


--
-- Name: table_statistics_metadata table_statistics_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.table_statistics_metadata
    ADD CONSTRAINT table_statistics_metadata_pkey PRIMARY KEY (table_name);


--
-- Name: telegram_integrations telegram_integrations_bot_token_encrypted; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.telegram_integrations
    ADD CONSTRAINT telegram_integrations_bot_token_encrypted CHECK ((bot_token ~~ 'enc:v1:%'::text)) NOT VALID;


--
-- Name: telegram_integrations telegram_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_integrations
    ADD CONSTRAINT telegram_integrations_pkey PRIMARY KEY (id);


--
-- Name: telegram_integrations telegram_integrations_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_integrations
    ADD CONSTRAINT telegram_integrations_subscription_id_key UNIQUE (subscription_id);


--
-- Name: telegram_messages telegram_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_messages
    ADD CONSTRAINT telegram_messages_pkey PRIMARY KEY (id);


--
-- Name: telegram_user_subscriptions telegram_user_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_user_subscriptions
    ADD CONSTRAINT telegram_user_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: telegram_user_subscriptions telegram_user_subscriptions_telegram_integration_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_user_subscriptions
    ADD CONSTRAINT telegram_user_subscriptions_telegram_integration_id_user_id_key UNIQUE (telegram_integration_id, user_id);


--
-- Name: template_usage_stats template_usage_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_usage_stats
    ADD CONSTRAINT template_usage_stats_pkey PRIMARY KEY (id);


--
-- Name: template_validation_log template_validation_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_validation_log
    ADD CONSTRAINT template_validation_log_pkey PRIMARY KEY (id);


--
-- Name: tenant_access_audit tenant_access_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_access_audit
    ADD CONSTRAINT tenant_access_audit_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: tenant_access_audit_2026_11 tenant_access_audit_2026_11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_access_audit_2026_11
    ADD CONSTRAINT tenant_access_audit_2026_11_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: tenant_access_audit_2026_12 tenant_access_audit_2026_12_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_access_audit_2026_12
    ADD CONSTRAINT tenant_access_audit_2026_12_pkey PRIMARY KEY (id, accessed_at);


--
-- Name: tenant_quotas tenant_quotas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_quotas
    ADD CONSTRAINT tenant_quotas_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenant_rls_policies tenant_rls_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_rls_policies
    ADD CONSTRAINT tenant_rls_policies_pkey PRIMARY KEY (id);


--
-- Name: tenant_rls_policies tenant_rls_policies_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_rls_policies
    ADD CONSTRAINT tenant_rls_policies_tenant_id_key UNIQUE (tenant_id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: token_transfers token_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.token_transfers
    ADD CONSTRAINT token_transfers_pkey PRIMARY KEY (event_id);


--
-- Name: tx_resources tx_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tx_resources
    ADD CONSTRAINT tx_resources_pkey PRIMARY KEY (tx_hash);


--
-- Name: webhook_configs webhook_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_configs
    ADD CONSTRAINT webhook_configs_pkey PRIMARY KEY (id);


--
-- Name: webhook_deliveries webhook_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: webhook_dlq webhook_dlq_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_dlq
    ADD CONSTRAINT webhook_dlq_pkey PRIMARY KEY (id);


--
-- Name: webhook_failures webhook_failures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_failures
    ADD CONSTRAINT webhook_failures_pkey PRIMARY KEY (id);


--
-- Name: webhook_log_access_audit webhook_log_access_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_log_access_audit
    ADD CONSTRAINT webhook_log_access_audit_pkey PRIMARY KEY (id);


--
-- Name: webhook_logs webhook_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_logs
    ADD CONSTRAINT webhook_logs_pkey PRIMARY KEY (id);


--
-- Name: webhook_retry_queue webhook_retry_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_retry_queue
    ADD CONSTRAINT webhook_retry_queue_pkey PRIMARY KEY (id);


--
-- Name: webhook_templates webhook_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_templates
    ADD CONSTRAINT webhook_templates_pkey PRIMARY KEY (id);


--
-- Name: webhook_templates webhook_templates_subscription_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_templates
    ADD CONSTRAINT webhook_templates_subscription_id_name_key UNIQUE (subscription_id, name);


--
-- Name: idx_abi_validation_log_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_abi_validation_log_contract ON public.contract_abi_validation_log USING btree (contract_id);


--
-- Name: idx_aggregation_errors_rule; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_aggregation_errors_rule ON public.aggregation_errors USING btree (rule_id, created_at DESC);


--
-- Name: idx_aggregation_results_rule; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_aggregation_results_rule ON public.aggregation_results USING btree (rule_id, window_start DESC);


--
-- Name: idx_aggregation_results_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_aggregation_results_subscription ON public.aggregation_results USING btree (subscription_id, created_at DESC);


--
-- Name: idx_aggregation_results_window; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_aggregation_results_window ON public.aggregation_results USING btree (rule_id, window_start, window_end);


--
-- Name: idx_aggregation_rules_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_aggregation_rules_subscription ON public.aggregation_rules USING btree (subscription_id, enabled, created_at DESC);


--
-- Name: idx_anomaly_alert_feedback_alert; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_alert_feedback_alert ON public.anomaly_alert_feedback USING btree (alert_id, created_at DESC);


--
-- Name: idx_anomaly_alerts_acknowledged; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_alerts_acknowledged ON public.anomaly_alerts USING btree (subscription_id, acknowledged, created_at DESC);


--
-- Name: idx_anomaly_alerts_severity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_alerts_severity ON public.anomaly_alerts USING btree (subscription_id, severity, created_at DESC);


--
-- Name: idx_anomaly_alerts_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_alerts_subscription ON public.anomaly_alerts USING btree (subscription_id, created_at DESC);


--
-- Name: idx_anomaly_feedback_alert; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_feedback_alert ON public.anomaly_feedback USING btree (alert_id);


--
-- Name: idx_anomaly_training_jobs_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_training_jobs_subscription ON public.anomaly_training_jobs USING btree (subscription_id, created_at DESC);


--
-- Name: idx_anonymization_rules_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anonymization_rules_enabled ON public.anonymization_rules USING btree (enabled);


--
-- Name: idx_api_key_tenants_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_key_tenants_tenant ON public.api_key_tenants USING btree (tenant_id);


--
-- Name: idx_api_keys_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_keys_created_at ON public.api_keys USING btree (created_at DESC);


--
-- Name: idx_api_request_logs_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_request_logs_tenant ON public.api_request_logs USING btree (tenant_id, "timestamp" DESC);


--
-- Name: idx_api_request_logs_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_request_logs_timestamp ON public.api_request_logs USING btree ("timestamp" DESC);


--
-- Name: idx_audit_logs_api_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_api_key_hash ON public.audit_logs USING btree (api_key_hash);


--
-- Name: idx_audit_logs_compliance_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_compliance_tags ON public.audit_logs USING gin (compliance_tags);


--
-- Name: idx_audit_logs_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_created_at ON public.audit_logs USING btree (created_at DESC);


--
-- Name: idx_audit_logs_event_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_event_created ON public.audit_logs USING btree (event_type, created_at DESC);


--
-- Name: idx_audit_logs_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_event_type ON public.audit_logs USING btree (event_type);


--
-- Name: idx_audit_logs_ip_address; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_ip_address ON public.audit_logs USING btree (ip_address);


--
-- Name: idx_audit_logs_resource_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_resource_created ON public.audit_logs USING btree (resource_type, resource_id, created_at DESC);


--
-- Name: idx_audit_logs_resource_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_resource_id ON public.audit_logs USING btree (resource_id);


--
-- Name: idx_audit_logs_resource_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_resource_type ON public.audit_logs USING btree (resource_type);


--
-- Name: idx_audit_logs_retention_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_retention_class ON public.audit_logs USING btree (retention_class);


--
-- Name: idx_audit_logs_severity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_severity ON public.audit_logs USING btree (severity);


--
-- Name: idx_audit_logs_signed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_signed_at ON public.audit_logs USING btree (signed_at) WHERE (signed_at IS NOT NULL);


--
-- Name: idx_audit_logs_success; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_success ON public.audit_logs USING btree (success);


--
-- Name: idx_audit_logs_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_user_created ON public.audit_logs USING btree (user_email, created_at DESC);


--
-- Name: idx_audit_logs_user_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_user_email ON public.audit_logs USING btree (user_email);


--
-- Name: idx_baseline_statistics_metric; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_baseline_statistics_metric ON public.baseline_statistics USING btree (metric_name);


--
-- Name: idx_baseline_statistics_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_baseline_statistics_subscription ON public.baseline_statistics USING btree (subscription_id, created_at DESC);


--
-- Name: idx_batch_jobs_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_jobs_created_at ON public.batch_download_jobs USING btree (created_at DESC);


--
-- Name: idx_batch_jobs_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_jobs_status ON public.batch_download_jobs USING btree (status);


--
-- Name: idx_bloom_state_persisted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bloom_state_persisted_at ON public.indexer_bloom_state USING btree (persisted_at DESC);


--
-- Name: idx_cache_config_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cache_config_tenant ON public.cache_config USING btree (tenant_id);


--
-- Name: idx_cache_stats_query_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cache_stats_query_type ON public.query_cache_stats USING btree (query_type);


--
-- Name: idx_cache_stats_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cache_stats_tenant_id ON public.query_cache_stats USING btree (tenant_id);


--
-- Name: idx_cache_stats_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cache_stats_updated_at ON public.query_cache_stats USING btree (updated_at DESC);


--
-- Name: idx_compliance_report_runs_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_compliance_report_runs_type ON public.compliance_report_runs USING btree (report_type, created_at DESC);


--
-- Name: idx_contract_abis_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contract_abis_expires_at ON public.contract_abis USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: idx_contract_abis_onchain_fetched; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contract_abis_onchain_fetched ON public.contract_abis USING btree (fetched_at) WHERE (source = 'onchain'::text);


--
-- Name: idx_contract_metadata_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contract_metadata_tags ON public.contract_metadata USING gin (tags);


--
-- Name: idx_contract_metadata_verified; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contract_metadata_verified ON public.contract_metadata USING btree (verified);


--
-- Name: idx_contract_schema_versions_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contract_schema_versions_contract ON public.contract_schema_versions USING btree (contract_id, version DESC);


--
-- Name: idx_contract_schemas_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contract_schemas_version ON public.contract_schemas USING btree (version);


--
-- Name: idx_contract_versions_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contract_versions_contract ON public.contract_versions USING btree (contract_id, id DESC);


--
-- Name: idx_contracts_deployer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contracts_deployer ON public.contracts USING btree (deployer) WHERE (deployer IS NOT NULL);


--
-- Name: idx_contracts_wasm_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contracts_wasm_hash ON public.contracts USING btree (wasm_hash);


--
-- Name: idx_cross_chain_correlations_networks; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cross_chain_correlations_networks ON public.cross_chain_correlations USING btree (source_network, target_network);


--
-- Name: idx_cross_chain_correlations_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cross_chain_correlations_source ON public.cross_chain_correlations USING btree (source_event_id);


--
-- Name: idx_cross_chain_correlations_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cross_chain_correlations_target ON public.cross_chain_correlations USING btree (target_event_id);


--
-- Name: idx_cross_chain_event_group_members_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cross_chain_event_group_members_event ON public.cross_chain_event_group_members USING btree (event_id);


--
-- Name: idx_delivery_queue_sub_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_queue_sub_status ON public.delivery_queue USING btree (subscription_id, status, next_attempt_at);


--
-- Name: idx_derived_metric_snapshots_labels; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_derived_metric_snapshots_labels ON public.derived_metric_snapshots USING gin (labels);


--
-- Name: idx_derived_metric_snapshots_name_evaluated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_derived_metric_snapshots_name_evaluated_at ON public.derived_metric_snapshots USING btree (metric_name, evaluated_at DESC);


--
-- Name: idx_detected_patterns_confidence; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_detected_patterns_confidence ON public.detected_patterns USING btree (confidence DESC);


--
-- Name: idx_detected_patterns_last_seen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_detected_patterns_last_seen ON public.detected_patterns USING btree (last_seen DESC);


--
-- Name: idx_detected_patterns_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_detected_patterns_type ON public.detected_patterns USING btree (pattern_type);


--
-- Name: idx_discord_integrations_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_discord_integrations_subscription ON public.discord_integrations USING btree (subscription_id);


--
-- Name: idx_discord_messages_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_discord_messages_event ON public.discord_messages USING btree (event_id);


--
-- Name: idx_discord_messages_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_discord_messages_integration ON public.discord_messages USING btree (discord_integration_id);


--
-- Name: idx_email_bounces_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_bounces_email ON public.email_bounces USING btree (email);


--
-- Name: idx_email_clicks_clicked_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_clicks_clicked_at ON public.email_clicks USING btree (clicked_at);


--
-- Name: idx_email_clicks_recipient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_clicks_recipient ON public.email_clicks USING btree (recipient);


--
-- Name: idx_email_clicks_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_clicks_token ON public.email_clicks USING btree (token);


--
-- Name: idx_email_deliveries_ab_template; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_deliveries_ab_template ON public.email_deliveries USING btree (ab_template);


--
-- Name: idx_email_deliveries_delivered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_deliveries_delivered_at ON public.email_deliveries USING btree (delivered_at);


--
-- Name: idx_email_deliveries_recipient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_deliveries_recipient ON public.email_deliveries USING btree (recipient);


--
-- Name: idx_email_delivery_log_address; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_log_address ON public.email_delivery_log USING btree (email_address, created_at DESC);


--
-- Name: idx_email_delivery_log_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_delivery_log_sub ON public.email_delivery_log USING btree (subscription_id, created_at DESC);


--
-- Name: idx_email_notifications_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_notifications_idempotency ON public.email_notifications USING btree (idempotency_key);


--
-- Name: idx_email_notifications_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_notifications_sent_at ON public.email_notifications USING btree (sent_at);


--
-- Name: idx_email_opens_opened_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_opens_opened_at ON public.email_opens USING btree (opened_at);


--
-- Name: idx_email_opens_recipient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_opens_recipient ON public.email_opens USING btree (recipient);


--
-- Name: idx_email_opens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_opens_token ON public.email_opens USING btree (token);


--
-- Name: idx_email_unsubscribes_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_unsubscribes_email ON public.email_unsubscribes USING btree (email);


--
-- Name: idx_email_unsubscribes_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_unsubscribes_token ON public.email_unsubscribes USING btree (token);


--
-- Name: idx_event_addresses_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_addresses_lookup ON public.event_addresses USING btree (address, ledger DESC, event_id DESC);


--
-- Name: idx_event_auto_tag_rules_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_auto_tag_rules_active ON public.event_auto_tag_rules USING btree (active) WHERE active;


--
-- Name: idx_event_auto_tag_rules_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_auto_tag_rules_tag_id ON public.event_auto_tag_rules USING btree (tag_id);


--
-- Name: idx_event_tag_assignments_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tag_assignments_event_id ON public.event_tag_assignments USING btree (event_id);


--
-- Name: idx_event_tag_assignments_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tag_assignments_tag_id ON public.event_tag_assignments USING btree (tag_id);


--
-- Name: idx_event_tags_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tags_parent_id ON public.event_tags USING btree (parent_id);


--
-- Name: idx_events_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_asset ON public.events USING btree (asset_code, asset_issuer) WHERE (asset_code IS NOT NULL);


--
-- Name: idx_events_chain_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_chain_contract ON public.events USING btree (chain_id, contract_id);


--
-- Name: idx_events_chain_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_chain_id ON public.events USING btree (chain_id);


--
-- Name: idx_events_contract_ledger_id_partial; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_contract_ledger_id_partial ON public.events USING btree (ledger DESC, id DESC) WHERE (event_type = 'contract'::text);


--
-- Name: idx_events_contract_summary_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_events_contract_summary_unique ON public.events_contract_summary USING btree (contract_id);


--
-- Name: idx_events_contract_type_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_contract_type_ledger ON public.events USING btree (contract_id, event_type, ledger DESC);


--
-- Name: idx_events_created_at_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_created_at_id ON public.events USING btree (created_at DESC, id DESC);


--
-- Name: idx_events_daily_summary_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_events_daily_summary_unique ON public.events_daily_summary USING btree (event_date, event_type);


--
-- Name: idx_events_event_data_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_event_data_gin ON public.events USING gin (event_data jsonb_path_ops);


--
-- Name: idx_events_event_data_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_event_data_tsv ON public.events USING gin (event_data_tsv);


--
-- Name: idx_events_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_fingerprint ON public.events USING btree (fingerprint) WHERE (fingerprint IS NOT NULL);


--
-- Name: idx_events_hourly_volume_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_events_hourly_volume_unique ON public.events_hourly_volume USING btree (event_hour);


--
-- Name: idx_events_ledger_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_ledger_desc ON public.events USING btree (ledger DESC);


--
-- Name: idx_events_ledger_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_ledger_hash ON public.events USING btree (ledger_hash);


--
-- Name: idx_events_ledger_ordinal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_ledger_ordinal ON public.events USING btree (ledger, tx_index, op_index, event_index);


--
-- Name: idx_events_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_location ON public.events USING btree (latitude, longitude) WHERE ((latitude IS NOT NULL) AND (longitude IS NOT NULL));


--
-- Name: idx_events_network; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_network ON public.events USING btree (network);


--
-- Name: idx_events_network_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_network_contract ON public.events USING btree (network, contract_id);


--
-- Name: idx_events_network_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_network_fingerprint ON public.events USING btree (network, fingerprint) WHERE (fingerprint IS NOT NULL);


--
-- Name: idx_events_notified_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_notified_at ON public.events USING btree (tx_hash, contract_id, event_type) WHERE (notified_at IS NOT NULL);


--
-- Name: idx_events_recent_ledger_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_recent_ledger_id ON public.events USING btree (ledger DESC, id DESC) WHERE (ledger > 0);


--
-- Name: idx_events_resource_stats; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_resource_stats ON public.events USING btree (contract_id, tx_hash) WHERE ((resource_fee IS NOT NULL) OR (cpu_insns IS NOT NULL) OR (mem_bytes IS NOT NULL));


--
-- Name: idx_events_schema_valid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_schema_valid ON public.events USING btree (schema_valid) WHERE (schema_valid = false);


--
-- Name: idx_events_sep41_from; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_sep41_from ON public.events USING btree (sep41_from, ledger DESC, id DESC) WHERE (sep41_event_type IS NOT NULL);


--
-- Name: idx_events_sep41_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_sep41_ledger ON public.events USING btree (ledger DESC, id DESC) WHERE (sep41_event_type IS NOT NULL);


--
-- Name: idx_events_sep41_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_sep41_to ON public.events USING btree (sep41_to, ledger DESC, id DESC) WHERE (sep41_event_type IS NOT NULL);


--
-- Name: idx_events_system_ledger_id_partial; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_system_ledger_id_partial ON public.events USING btree (ledger DESC, id DESC) WHERE (event_type = 'system'::text);


--
-- Name: idx_events_tenant_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_tenant_contract ON public.events USING btree (tenant_id, contract_id);


--
-- Name: idx_events_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_tenant_id ON public.events USING btree (tenant_id) WHERE (tenant_id IS NOT NULL);


--
-- Name: idx_events_tenant_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_tenant_ledger ON public.events USING btree (tenant_id, ledger DESC);


--
-- Name: idx_events_tenant_ledger_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_tenant_ledger_id ON public.events USING btree (tenant_id, ledger DESC, id DESC) WHERE (tenant_id IS NOT NULL);


--
-- Name: idx_events_tenant_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_tenant_timestamp ON public.events USING btree (tenant_id, "timestamp" DESC);


--
-- Name: idx_events_timestamp_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_timestamp_id ON public.events USING btree ("timestamp" DESC, id DESC);


--
-- Name: idx_events_topic_0_sym; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_topic_0_sym ON public.events USING btree (topic_0_sym);


--
-- Name: idx_events_topic_1_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_topic_1_gin ON public.events USING gin ((((event_data -> 'topic'::text) -> 1)) jsonb_path_ops);


--
-- Name: idx_events_topic_2_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_topic_2_gin ON public.events USING gin ((((event_data -> 'topic'::text) -> 2)) jsonb_path_ops);


--
-- Name: idx_events_topic_3_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_topic_3_gin ON public.events USING gin ((((event_data -> 'topic'::text) -> 3)) jsonb_path_ops);


--
-- Name: idx_events_tx_hash_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_events_tx_hash_contract ON public.events USING btree (tx_hash, contract_id, event_type);


--
-- Name: idx_events_tx_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_tx_ledger ON public.events USING btree (tx_hash, ledger DESC);


--
-- Name: idx_events_type_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_type_ledger ON public.events USING btree (event_type, ledger DESC);


--
-- Name: idx_events_uncompressed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_uncompressed ON public.events USING btree (id) WHERE (event_data_compressed IS NULL);


--
-- Name: idx_feature_flag_audit_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_feature_flag_audit_created_at ON public.feature_flag_audit USING btree (created_at DESC);


--
-- Name: idx_feature_flag_audit_flag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_feature_flag_audit_flag_id ON public.feature_flag_audit USING btree (flag_id);


--
-- Name: idx_feature_flags_rollout_pct; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_feature_flags_rollout_pct ON public.feature_flags USING btree (rollout_percentage) WHERE (enabled = true);


--
-- Name: idx_feature_flags_targets; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_feature_flags_targets ON public.feature_flags USING gin (target_contract_ids, target_user_ids) WHERE (enabled = true);


--
-- Name: idx_gdpr_consent_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gdpr_consent_email ON public.gdpr_consent_records USING btree (subject_email);


--
-- Name: idx_gdpr_consent_granted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gdpr_consent_granted ON public.gdpr_consent_records USING btree (granted);


--
-- Name: idx_gdpr_consent_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gdpr_consent_type ON public.gdpr_consent_records USING btree (consent_type);


--
-- Name: idx_gdpr_dsr_deadline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gdpr_dsr_deadline ON public.gdpr_data_subject_requests USING btree (deadline_at) WHERE ((status <> 'completed'::text) AND (status <> 'rejected'::text));


--
-- Name: idx_gdpr_dsr_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gdpr_dsr_email ON public.gdpr_data_subject_requests USING btree (subject_email);


--
-- Name: idx_gdpr_dsr_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gdpr_dsr_status ON public.gdpr_data_subject_requests USING btree (status);


--
-- Name: idx_github_integrations_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_github_integrations_subscription ON public.github_integrations USING btree (subscription_id);


--
-- Name: idx_github_issues_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_github_issues_event ON public.github_issues USING btree (event_id);


--
-- Name: idx_github_issues_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_github_issues_integration ON public.github_issues USING btree (github_integration_id);


--
-- Name: idx_group_metrics_group_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_metrics_group_key ON public.group_metrics USING btree (group_key, window_start DESC);


--
-- Name: idx_group_metrics_rule_group_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_metrics_rule_group_time ON public.group_metrics USING btree (rule_id, group_key, window_start DESC);


--
-- Name: idx_group_metrics_rule_window; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_metrics_rule_window ON public.group_metrics USING btree (rule_id, window_start DESC, window_end);


--
-- Name: idx_group_metrics_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_metrics_subscription ON public.group_metrics USING btree (subscription_id, computed_at DESC);


--
-- Name: idx_incidents_kind_opened_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_incidents_kind_opened_at ON public.incidents USING btree (kind, opened_at DESC);


--
-- Name: idx_incidents_status_opened_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_incidents_status_opened_at ON public.incidents USING btree (status, opened_at DESC);


--
-- Name: idx_intelligent_filters_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_intelligent_filters_active ON public.intelligent_filters USING btree (is_active);


--
-- Name: idx_intelligent_filters_confidence; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_intelligent_filters_confidence ON public.intelligent_filters USING btree (confidence DESC);


--
-- Name: idx_invalidation_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invalidation_tenant_created ON public.cache_invalidation_log USING btree (tenant_id, created_at DESC);


--
-- Name: idx_invalidation_trigger_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invalidation_trigger_event ON public.cache_invalidation_log USING btree (trigger_event);


--
-- Name: idx_ledger_hashes_indexed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_hashes_indexed_at ON public.ledger_hashes USING btree (indexed_at);


--
-- Name: idx_maintenance_windows_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_maintenance_windows_active ON public.maintenance_windows USING btree (start_time, end_time);


--
-- Name: idx_metric_history_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_metric_history_subscription ON public.metric_history USING btree (subscription_id, metric_name, "timestamp" DESC);


--
-- Name: idx_metric_history_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_metric_history_tenant ON public.metric_history USING btree (tenant_id, "timestamp" DESC) WHERE (tenant_id IS NOT NULL);


--
-- Name: idx_ml_models_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ml_models_active ON public.ml_models USING btree (is_active);


--
-- Name: idx_ml_models_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ml_models_name ON public.ml_models USING btree (name);


--
-- Name: idx_ml_models_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ml_models_type ON public.ml_models USING btree (model_type);


--
-- Name: idx_ml_predictions_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ml_predictions_model ON public.ml_predictions USING btree (model_id, prediction_time DESC);


--
-- Name: idx_ml_predictions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ml_predictions_type ON public.ml_predictions USING btree (prediction_type);


--
-- Name: idx_ml_predictions_valid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ml_predictions_valid ON public.ml_predictions USING btree (valid_until) WHERE (valid_until IS NOT NULL);


--
-- Name: idx_mv_contract_resource_stats; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_mv_contract_resource_stats ON public.mv_contract_resource_stats USING btree (contract_id);


--
-- Name: idx_mv_contract_resources_daily; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_mv_contract_resources_daily ON public.mv_contract_resources_daily USING btree (contract_id, day);


--
-- Name: idx_mv_contract_summary_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_mv_contract_summary_contract_id ON public.mv_contract_summary USING btree (contract_id);


--
-- Name: idx_mv_contract_summary_event_count; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mv_contract_summary_event_count ON public.mv_contract_summary USING btree (event_count DESC);


--
-- Name: idx_mv_contract_summary_first_event_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mv_contract_summary_first_event_timestamp ON public.mv_contract_summary USING btree (first_event_timestamp);


--
-- Name: idx_mv_contract_summary_latest_event_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mv_contract_summary_latest_event_timestamp ON public.mv_contract_summary USING btree (latest_event_timestamp DESC);


--
-- Name: idx_ncgm_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ncgm_channel_id ON public.notification_channel_group_members USING btree (channel_id);


--
-- Name: idx_ncgm_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ncgm_group_id ON public.notification_channel_group_members USING btree (group_id);


--
-- Name: idx_ncv_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ncv_channel_id ON public.notification_channel_versions USING btree (channel_id);


--
-- Name: idx_normalization_rules_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_normalization_rules_contract_id ON public.normalization_rules USING btree (contract_id);


--
-- Name: idx_notif_ack_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notif_ack_channel ON public.notification_acknowledgments USING btree (channel);


--
-- Name: idx_notif_ack_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notif_ack_status_created ON public.notification_acknowledgments USING btree (status, created_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: idx_notification_audit_log_channel_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_audit_log_channel_type ON public.notification_audit_log USING btree (channel_type);


--
-- Name: idx_notification_audit_log_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_audit_log_status ON public.notification_audit_log USING btree (status);


--
-- Name: idx_notification_audit_log_triggered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_audit_log_triggered_at ON public.notification_audit_log USING btree (triggered_at);


--
-- Name: idx_notification_channels_channel_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_channels_channel_type ON public.notification_channels USING btree (channel_type);


--
-- Name: idx_notification_channels_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_channels_fts ON public.notification_channels USING gin (to_tsvector('english'::regconfig, ((name || ' '::text) || COALESCE(description, ''::text))));


--
-- Name: idx_notification_channels_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_channels_owner ON public.notification_channels USING btree (owner);


--
-- Name: idx_notification_channels_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_channels_status ON public.notification_channels USING btree (status);


--
-- Name: idx_notification_channels_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_channels_tags ON public.notification_channels USING gin (tags);


--
-- Name: idx_notification_costs_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_costs_channel_id ON public.notification_costs USING btree (channel_id);


--
-- Name: idx_notification_costs_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_costs_sent_at ON public.notification_costs USING btree (sent_at);


--
-- Name: idx_notification_deliveries_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_deliveries_channel ON public.notification_deliveries USING btree (channel_type, status, delivered_at DESC);


--
-- Name: idx_notification_deliveries_channel_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_deliveries_channel_type ON public.notification_deliveries USING btree (channel_type);


--
-- Name: idx_notification_deliveries_delivered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_deliveries_delivered_at ON public.notification_deliveries USING btree (delivered_at DESC);


--
-- Name: idx_notification_deliveries_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_deliveries_event_id ON public.notification_deliveries USING btree (event_id);


--
-- Name: idx_notification_deliveries_retention; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_deliveries_retention ON public.notification_deliveries USING btree (delivered_at);


--
-- Name: idx_notification_templates_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_templates_active ON public.notification_templates USING btree (name, is_active) WHERE (is_active = true);


--
-- Name: idx_notification_templates_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_templates_name ON public.notification_templates USING btree (name);


--
-- Name: idx_pagerduty_configs_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pagerduty_configs_active ON public.pagerduty_configs USING btree (active);


--
-- Name: idx_partition_drops_dropped_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partition_drops_dropped_at ON public.partition_drops_log USING btree (dropped_at DESC);


--
-- Name: idx_pd_escalation_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pd_escalation_integration ON public.pagerduty_escalation_policies USING btree (integration_id);


--
-- Name: idx_pd_incidents_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pd_incidents_contract ON public.pagerduty_incidents USING btree (contract_id);


--
-- Name: idx_pd_incidents_dedup_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pd_incidents_dedup_key ON public.pagerduty_incidents USING btree (dedup_key);


--
-- Name: idx_pd_incidents_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pd_incidents_integration ON public.pagerduty_incidents USING btree (integration_id);


--
-- Name: idx_pd_incidents_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pd_incidents_status ON public.pagerduty_incidents USING btree (status);


--
-- Name: idx_pd_integrations_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pd_integrations_subscription ON public.pagerduty_integrations USING btree (subscription_id);


--
-- Name: idx_pool_config_history_applied_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pool_config_history_applied_at ON public.pool_config_history USING btree (applied_at DESC);


--
-- Name: idx_pool_tuning_snapshots_recorded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pool_tuning_snapshots_recorded_at ON public.pool_tuning_snapshots USING btree (recorded_at DESC);


--
-- Name: idx_push_delivery_log_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_push_delivery_log_sub ON public.push_delivery_log USING btree (subscription_id, created_at DESC);


--
-- Name: idx_query_explain_cache_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_query_explain_cache_expires ON public.query_explain_cache USING btree (expires_at);


--
-- Name: idx_rate_limit_active_windows; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rate_limit_active_windows ON public.rate_limit_counters USING btree (api_key_hash, window_start DESC);


--
-- Name: idx_rate_limit_api_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rate_limit_api_key_hash ON public.rate_limit_counters USING btree (api_key_hash);


--
-- Name: idx_rate_limit_endpoints_backoff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rate_limit_endpoints_backoff ON public.rate_limit_endpoints USING btree (backoff_until) WHERE (backoff_until IS NOT NULL);


--
-- Name: idx_rate_limit_endpoints_health; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rate_limit_endpoints_health ON public.rate_limit_endpoints USING btree (health_status);


--
-- Name: idx_rate_limit_window_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rate_limit_window_start ON public.rate_limit_counters USING btree (window_start);


--
-- Name: idx_replay_delivery_log_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_replay_delivery_log_event ON public.replay_delivery_log USING btree (event_id, replay_id);


--
-- Name: idx_replay_delivery_log_replay; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_replay_delivery_log_replay ON public.replay_delivery_log USING btree (replay_id, status);


--
-- Name: idx_replay_schedules_next_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_replay_schedules_next_run ON public.replay_schedules USING btree (next_run_at, is_active) WHERE (is_active = true);


--
-- Name: idx_replay_schedules_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_replay_schedules_subscription ON public.replay_schedules USING btree (subscription_id, is_active);


--
-- Name: idx_replay_status_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_replay_status_status ON public.replay_status USING btree (status, created_at DESC);


--
-- Name: idx_replay_status_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_replay_status_subscription ON public.replay_status USING btree (subscription_id, created_at DESC);


--
-- Name: idx_saas_tenants_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_saas_tenants_status ON public.saas_tenants USING btree (status);


--
-- Name: idx_saas_tenants_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_saas_tenants_tenant_id ON public.saas_tenants USING btree (tenant_id);


--
-- Name: idx_saas_tenants_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_saas_tenants_tier ON public.saas_tenants USING btree (subscription_tier);


--
-- Name: idx_saas_tenants_trial_ends; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_saas_tenants_trial_ends ON public.saas_tenants USING btree (trial_ends_at) WHERE (trial_ends_at IS NOT NULL);


--
-- Name: idx_saved_queries_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_saved_queries_created_at ON public.saved_queries USING btree (created_at DESC);


--
-- Name: idx_saved_queries_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_saved_queries_created_by ON public.saved_queries USING btree (created_by);


--
-- Name: idx_saved_queries_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_saved_queries_name ON public.saved_queries USING btree (name);


--
-- Name: idx_scheduled_replay_runs_schedule; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scheduled_replay_runs_schedule ON public.scheduled_replay_runs USING btree (schedule_id, started_at DESC);


--
-- Name: idx_slack_integrations_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_slack_integrations_subscription ON public.slack_integrations USING btree (subscription_id);


--
-- Name: idx_slack_messages_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_slack_messages_event ON public.slack_messages USING btree (event_id);


--
-- Name: idx_slack_messages_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_slack_messages_integration ON public.slack_messages USING btree (slack_integration_id);


--
-- Name: idx_slack_user_subscriptions_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_slack_user_subscriptions_integration ON public.slack_user_subscriptions USING btree (slack_integration_id);


--
-- Name: idx_slow_query_log_avg_duration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_slow_query_log_avg_duration ON public.slow_query_log USING btree (avg_duration_ms DESC);


--
-- Name: idx_slow_query_log_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_slow_query_log_fingerprint ON public.slow_query_log USING btree (query_fingerprint);


--
-- Name: idx_sms_notifications_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sms_notifications_created_at ON public.sms_notifications USING btree (created_at DESC);


--
-- Name: idx_sms_notifications_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sms_notifications_phone ON public.sms_notifications USING btree (phone_number);


--
-- Name: idx_sms_notifications_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sms_notifications_status ON public.sms_notifications USING btree (status);


--
-- Name: idx_statistics_jobs_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statistics_jobs_started_at ON public.statistics_analysis_jobs USING btree (started_at DESC);


--
-- Name: idx_statistics_jobs_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statistics_jobs_status ON public.statistics_analysis_jobs USING btree (status);


--
-- Name: idx_statistics_jobs_table_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statistics_jobs_table_name ON public.statistics_analysis_jobs USING btree (table_name);


--
-- Name: idx_subscription_pause_resume_log_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscription_pause_resume_log_action ON public.subscription_pause_resume_log USING btree (subscription_id, action, created_at DESC);


--
-- Name: idx_subscription_pause_resume_log_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscription_pause_resume_log_subscription ON public.subscription_pause_resume_log USING btree (subscription_id, created_at DESC);


--
-- Name: idx_subscriptions_pause_until; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscriptions_pause_until ON public.subscriptions USING btree (pause_until) WHERE (pause_until IS NOT NULL);


--
-- Name: idx_subscriptions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscriptions_type ON public.subscriptions USING btree (subscription_type);


--
-- Name: idx_suppression_lists_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_suppression_lists_expires ON public.suppression_lists USING btree (expires_at);


--
-- Name: idx_suppression_lists_target; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_suppression_lists_target ON public.suppression_lists USING btree (target, target_type);


--
-- Name: idx_suppression_lists_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_suppression_lists_type ON public.suppression_lists USING btree (target_type);


--
-- Name: idx_table_statistics_is_stale; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_table_statistics_is_stale ON public.table_statistics_metadata USING btree (is_stale);


--
-- Name: idx_table_statistics_last_analyzed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_table_statistics_last_analyzed ON public.table_statistics_metadata USING btree (last_analyzed DESC);


--
-- Name: idx_telegram_integrations_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telegram_integrations_subscription ON public.telegram_integrations USING btree (subscription_id);


--
-- Name: idx_telegram_messages_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telegram_messages_event ON public.telegram_messages USING btree (event_id);


--
-- Name: idx_telegram_messages_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telegram_messages_integration ON public.telegram_messages USING btree (telegram_integration_id);


--
-- Name: idx_telegram_user_subscriptions_integration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telegram_user_subscriptions_integration ON public.telegram_user_subscriptions USING btree (telegram_integration_id);


--
-- Name: idx_template_usage_stats_template; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_template_usage_stats_template ON public.template_usage_stats USING btree (webhook_template_id);


--
-- Name: idx_template_validation_log_template; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_template_validation_log_template ON public.template_validation_log USING btree (webhook_template_id, created_at DESC);


--
-- Name: idx_tenant_audit_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_audit_failures ON ONLY public.tenant_access_audit USING btree (tenant_id, accessed_at DESC) WHERE (response_status >= 400);


--
-- Name: idx_tenant_audit_key_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_audit_key_time ON ONLY public.tenant_access_audit USING btree (api_key_hash, accessed_at DESC);


--
-- Name: idx_tenant_audit_tenant_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_audit_tenant_time ON ONLY public.tenant_access_audit USING btree (tenant_id, accessed_at DESC) WHERE (tenant_id IS NOT NULL);


--
-- Name: idx_tenant_audit_trace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_audit_trace_id ON ONLY public.tenant_access_audit USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: idx_tenant_rls_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_rls_tenant_id ON public.tenant_rls_policies USING btree (tenant_id);


--
-- Name: idx_tenants_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenants_created_at ON public.tenants USING btree (created_at);


--
-- Name: idx_token_transfers_contract; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_token_transfers_contract ON public.token_transfers USING btree (contract_id, ledger DESC, event_id DESC);


--
-- Name: idx_token_transfers_from; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_token_transfers_from ON public.token_transfers USING btree (from_address);


--
-- Name: idx_token_transfers_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_token_transfers_ledger ON public.token_transfers USING btree (ledger);


--
-- Name: idx_token_transfers_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_token_transfers_to ON public.token_transfers USING btree (to_address);


--
-- Name: idx_ts_cache_computed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ts_cache_computed_at ON public.event_time_series_cache USING btree (computed_at);


--
-- Name: idx_ts_cache_contract_granularity_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ts_cache_contract_granularity_start ON public.event_time_series_cache USING btree (contract_id, granularity, bucket_start);


--
-- Name: idx_ts_cache_granularity_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ts_cache_granularity_start ON public.event_time_series_cache USING btree (granularity, bucket_start);


--
-- Name: idx_tx_resources_contract_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tx_resources_contract_time ON public.tx_resources USING btree (contract_id, closed_at);


--
-- Name: idx_webhook_configs_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_configs_active ON public.webhook_configs USING btree (active);


--
-- Name: idx_webhook_configs_format; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_configs_format ON public.webhook_configs USING btree (notification_format);


--
-- Name: idx_webhook_deliveries_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_deliveries_tenant ON public.webhook_deliveries USING btree (tenant_id, created_at DESC);


--
-- Name: idx_webhook_dlq_failed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_dlq_failed_at ON public.webhook_dlq USING btree (failed_at);


--
-- Name: idx_webhook_dlq_replayed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_dlq_replayed_at ON public.webhook_dlq USING btree (replayed_at);


--
-- Name: idx_webhook_dlq_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_dlq_subscription_id ON public.webhook_dlq USING btree (subscription_id);


--
-- Name: idx_webhook_failures_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_failures_created_at ON public.webhook_failures USING btree (created_at DESC);


--
-- Name: idx_webhook_failures_next_retry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_failures_next_retry ON public.webhook_failures USING btree (next_retry_at);


--
-- Name: idx_webhook_log_access_audit_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_log_access_audit_created_at ON public.webhook_log_access_audit USING btree (created_at DESC);


--
-- Name: idx_webhook_logs_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_logs_contract_id ON public.webhook_logs USING btree (contract_id, created_at DESC) WHERE (contract_id IS NOT NULL);


--
-- Name: idx_webhook_logs_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_logs_created_at ON public.webhook_logs USING btree (created_at DESC);


--
-- Name: idx_webhook_logs_response_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_logs_response_status ON public.webhook_logs USING btree (response_status, created_at DESC) WHERE (response_status IS NOT NULL);


--
-- Name: idx_webhook_logs_url; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_logs_url ON public.webhook_logs USING btree (url, created_at DESC);


--
-- Name: idx_webhook_retry_queue_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_retry_queue_created_at ON public.webhook_retry_queue USING btree (created_at DESC);


--
-- Name: idx_webhook_retry_queue_status_next_retry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_retry_queue_status_next_retry ON public.webhook_retry_queue USING btree (status, next_retry_at) WHERE (status = 'pending'::text);


--
-- Name: idx_webhook_templates_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_webhook_templates_subscription ON public.webhook_templates USING btree (subscription_id, is_active);


--
-- Name: mv_contract_event_counts_contract_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mv_contract_event_counts_contract_idx ON public.mv_contract_event_counts USING btree (contract_id);


--
-- Name: mv_contract_event_counts_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX mv_contract_event_counts_uniq ON public.mv_contract_event_counts USING btree (contract_id, event_type, event_day);


--
-- Name: tenant_access_audit_2026_11_api_key_hash_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_11_api_key_hash_accessed_at_idx ON public.tenant_access_audit_2026_11 USING btree (api_key_hash, accessed_at DESC);


--
-- Name: tenant_access_audit_2026_11_tenant_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_11_tenant_id_accessed_at_idx ON public.tenant_access_audit_2026_11 USING btree (tenant_id, accessed_at DESC) WHERE (tenant_id IS NOT NULL);


--
-- Name: tenant_access_audit_2026_11_tenant_id_accessed_at_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_11_tenant_id_accessed_at_idx1 ON public.tenant_access_audit_2026_11 USING btree (tenant_id, accessed_at DESC) WHERE (response_status >= 400);


--
-- Name: tenant_access_audit_2026_11_trace_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_11_trace_id_idx ON public.tenant_access_audit_2026_11 USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: tenant_access_audit_2026_12_api_key_hash_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_12_api_key_hash_accessed_at_idx ON public.tenant_access_audit_2026_12 USING btree (api_key_hash, accessed_at DESC);


--
-- Name: tenant_access_audit_2026_12_tenant_id_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_12_tenant_id_accessed_at_idx ON public.tenant_access_audit_2026_12 USING btree (tenant_id, accessed_at DESC) WHERE (tenant_id IS NOT NULL);


--
-- Name: tenant_access_audit_2026_12_tenant_id_accessed_at_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_12_tenant_id_accessed_at_idx1 ON public.tenant_access_audit_2026_12 USING btree (tenant_id, accessed_at DESC) WHERE (response_status >= 400);


--
-- Name: tenant_access_audit_2026_12_trace_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_access_audit_2026_12_trace_id_idx ON public.tenant_access_audit_2026_12 USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: tenant_access_audit_2026_11_api_key_hash_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_key_time ATTACH PARTITION public.tenant_access_audit_2026_11_api_key_hash_accessed_at_idx;


--
-- Name: tenant_access_audit_2026_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.tenant_access_audit_pkey ATTACH PARTITION public.tenant_access_audit_2026_11_pkey;


--
-- Name: tenant_access_audit_2026_11_tenant_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_tenant_time ATTACH PARTITION public.tenant_access_audit_2026_11_tenant_id_accessed_at_idx;


--
-- Name: tenant_access_audit_2026_11_tenant_id_accessed_at_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_failures ATTACH PARTITION public.tenant_access_audit_2026_11_tenant_id_accessed_at_idx1;


--
-- Name: tenant_access_audit_2026_11_trace_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_trace_id ATTACH PARTITION public.tenant_access_audit_2026_11_trace_id_idx;


--
-- Name: tenant_access_audit_2026_12_api_key_hash_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_key_time ATTACH PARTITION public.tenant_access_audit_2026_12_api_key_hash_accessed_at_idx;


--
-- Name: tenant_access_audit_2026_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.tenant_access_audit_pkey ATTACH PARTITION public.tenant_access_audit_2026_12_pkey;


--
-- Name: tenant_access_audit_2026_12_tenant_id_accessed_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_tenant_time ATTACH PARTITION public.tenant_access_audit_2026_12_tenant_id_accessed_at_idx;


--
-- Name: tenant_access_audit_2026_12_tenant_id_accessed_at_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_failures ATTACH PARTITION public.tenant_access_audit_2026_12_tenant_id_accessed_at_idx1;


--
-- Name: tenant_access_audit_2026_12_trace_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.idx_tenant_audit_trace_id ATTACH PARTITION public.tenant_access_audit_2026_12_trace_id_idx;


--
-- Name: events mark_events_stats_stale; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER mark_events_stats_stale AFTER INSERT OR DELETE OR UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.mark_statistics_stale();


--
-- Name: contract_schemas trg_schema_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_schema_version BEFORE UPDATE ON public.contract_schemas FOR EACH ROW EXECUTE FUNCTION public.increment_schema_version();


--
-- Name: tenant_quotas trg_tenant_quotas_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_tenant_quotas_updated_at BEFORE UPDATE ON public.tenant_quotas FOR EACH ROW EXECUTE FUNCTION public.touch_tenant_quotas_updated_at();


--
-- Name: events trigger_extract_coordinates; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_extract_coordinates BEFORE INSERT OR UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.extract_coordinates_from_event_data();


--
-- Name: audit_logs trigger_set_audit_log_retention; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_set_audit_log_retention BEFORE INSERT ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION public.set_audit_log_retention();


--
-- Name: intelligent_filters update_intelligent_filters_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_intelligent_filters_updated_at BEFORE UPDATE ON public.intelligent_filters FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: ml_models update_ml_models_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_ml_models_updated_at BEFORE UPDATE ON public.ml_models FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: saas_tenants update_saas_tenants_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_saas_tenants_updated_at BEFORE UPDATE ON public.saas_tenants FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: aggregation_errors aggregation_errors_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aggregation_errors
    ADD CONSTRAINT aggregation_errors_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.aggregation_rules(id) ON DELETE CASCADE;


--
-- Name: aggregation_results aggregation_results_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aggregation_results
    ADD CONSTRAINT aggregation_results_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.aggregation_rules(id) ON DELETE CASCADE;


--
-- Name: aggregation_results aggregation_results_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aggregation_results
    ADD CONSTRAINT aggregation_results_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: aggregation_rules aggregation_rules_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aggregation_rules
    ADD CONSTRAINT aggregation_rules_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: anomaly_alert_feedback anomaly_alert_feedback_alert_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_alert_feedback
    ADD CONSTRAINT anomaly_alert_feedback_alert_id_fkey FOREIGN KEY (alert_id) REFERENCES public.anomaly_alerts(id) ON DELETE CASCADE;


--
-- Name: anomaly_alerts anomaly_alerts_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_alerts
    ADD CONSTRAINT anomaly_alerts_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: anomaly_feedback anomaly_feedback_alert_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_feedback
    ADD CONSTRAINT anomaly_feedback_alert_id_fkey FOREIGN KEY (alert_id) REFERENCES public.anomaly_alerts(id) ON DELETE CASCADE;


--
-- Name: anomaly_feedback anomaly_feedback_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_feedback
    ADD CONSTRAINT anomaly_feedback_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: anomaly_training_jobs anomaly_training_jobs_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_training_jobs
    ADD CONSTRAINT anomaly_training_jobs_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: baseline_statistics baseline_statistics_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.baseline_statistics
    ADD CONSTRAINT baseline_statistics_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: cross_chain_correlations cross_chain_correlations_source_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_correlations
    ADD CONSTRAINT cross_chain_correlations_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: cross_chain_correlations cross_chain_correlations_target_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_correlations
    ADD CONSTRAINT cross_chain_correlations_target_event_id_fkey FOREIGN KEY (target_event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: cross_chain_event_group_members cross_chain_event_group_members_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_event_group_members
    ADD CONSTRAINT cross_chain_event_group_members_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: cross_chain_event_group_members cross_chain_event_group_members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_chain_event_group_members
    ADD CONSTRAINT cross_chain_event_group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.cross_chain_event_groups(id) ON DELETE CASCADE;


--
-- Name: delivery_queue delivery_queue_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_queue
    ADD CONSTRAINT delivery_queue_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: delivery_queue delivery_queue_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_queue
    ADD CONSTRAINT delivery_queue_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: discord_integrations discord_integrations_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discord_integrations
    ADD CONSTRAINT discord_integrations_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: discord_messages discord_messages_discord_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discord_messages
    ADD CONSTRAINT discord_messages_discord_integration_id_fkey FOREIGN KEY (discord_integration_id) REFERENCES public.discord_integrations(id) ON DELETE CASCADE;


--
-- Name: email_clicks email_clicks_email_notification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_clicks
    ADD CONSTRAINT email_clicks_email_notification_id_fkey FOREIGN KEY (email_notification_id) REFERENCES public.email_notifications(id) ON DELETE CASCADE;


--
-- Name: email_deliveries email_deliveries_email_notification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_deliveries
    ADD CONSTRAINT email_deliveries_email_notification_id_fkey FOREIGN KEY (email_notification_id) REFERENCES public.email_notifications(id) ON DELETE CASCADE;


--
-- Name: email_delivery_log email_delivery_log_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_delivery_log
    ADD CONSTRAINT email_delivery_log_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE SET NULL;


--
-- Name: email_opens email_opens_email_notification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_opens
    ADD CONSTRAINT email_opens_email_notification_id_fkey FOREIGN KEY (email_notification_id) REFERENCES public.email_notifications(id) ON DELETE CASCADE;


--
-- Name: event_auto_tag_rules event_auto_tag_rules_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_auto_tag_rules
    ADD CONSTRAINT event_auto_tag_rules_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.event_tags(id) ON DELETE CASCADE;


--
-- Name: event_tag_assignments event_tag_assignments_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_tag_assignments
    ADD CONSTRAINT event_tag_assignments_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE;


--
-- Name: event_tag_assignments event_tag_assignments_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_tag_assignments
    ADD CONSTRAINT event_tag_assignments_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.event_tags(id) ON DELETE CASCADE;


--
-- Name: event_tags event_tags_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_tags
    ADD CONSTRAINT event_tags_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.event_tags(id) ON DELETE SET NULL;


--
-- Name: feature_flag_audit feature_flag_audit_flag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feature_flag_audit
    ADD CONSTRAINT feature_flag_audit_flag_id_fkey FOREIGN KEY (flag_id) REFERENCES public.feature_flags(id) ON DELETE CASCADE;


--
-- Name: github_integrations github_integrations_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_integrations
    ADD CONSTRAINT github_integrations_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: github_issues github_issues_github_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_issues
    ADD CONSTRAINT github_issues_github_integration_id_fkey FOREIGN KEY (github_integration_id) REFERENCES public.github_integrations(id) ON DELETE CASCADE;


--
-- Name: group_metrics group_metrics_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_metrics
    ADD CONSTRAINT group_metrics_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.aggregation_rules(id) ON DELETE CASCADE;


--
-- Name: group_metrics group_metrics_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_metrics
    ADD CONSTRAINT group_metrics_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: ml_predictions ml_predictions_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ml_predictions
    ADD CONSTRAINT ml_predictions_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.ml_models(id);


--
-- Name: notification_channel_group_members notification_channel_group_members_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_group_members
    ADD CONSTRAINT notification_channel_group_members_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.notification_channels(id) ON DELETE CASCADE;


--
-- Name: notification_channel_group_members notification_channel_group_members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_group_members
    ADD CONSTRAINT notification_channel_group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.notification_channel_groups(id) ON DELETE CASCADE;


--
-- Name: notification_channel_versions notification_channel_versions_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channel_versions
    ADD CONSTRAINT notification_channel_versions_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.notification_channels(id) ON DELETE CASCADE;


--
-- Name: notification_channels notification_channels_failover_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_channels
    ADD CONSTRAINT notification_channels_failover_channel_id_fkey FOREIGN KEY (failover_channel_id) REFERENCES public.notification_channels(id) ON DELETE SET NULL;


--
-- Name: notification_costs notification_costs_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_costs
    ADD CONSTRAINT notification_costs_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.notification_channels(id) ON DELETE CASCADE;


--
-- Name: pagerduty_escalation_policies pagerduty_escalation_policies_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_escalation_policies
    ADD CONSTRAINT pagerduty_escalation_policies_integration_id_fkey FOREIGN KEY (integration_id) REFERENCES public.pagerduty_integrations(id) ON DELETE CASCADE;


--
-- Name: pagerduty_incidents pagerduty_incidents_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_incidents
    ADD CONSTRAINT pagerduty_incidents_integration_id_fkey FOREIGN KEY (integration_id) REFERENCES public.pagerduty_integrations(id) ON DELETE SET NULL;


--
-- Name: pagerduty_integrations pagerduty_integrations_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pagerduty_integrations
    ADD CONSTRAINT pagerduty_integrations_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: push_delivery_log push_delivery_log_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_delivery_log
    ADD CONSTRAINT push_delivery_log_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE SET NULL;


--
-- Name: replay_delivery_log replay_delivery_log_replay_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replay_delivery_log
    ADD CONSTRAINT replay_delivery_log_replay_id_fkey FOREIGN KEY (replay_id) REFERENCES public.replay_status(id) ON DELETE CASCADE;


--
-- Name: replay_schedules replay_schedules_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replay_schedules
    ADD CONSTRAINT replay_schedules_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: replay_status replay_status_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replay_status
    ADD CONSTRAINT replay_status_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: scheduled_replay_runs scheduled_replay_runs_replay_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_replay_runs
    ADD CONSTRAINT scheduled_replay_runs_replay_id_fkey FOREIGN KEY (replay_id) REFERENCES public.replay_status(id);


--
-- Name: scheduled_replay_runs scheduled_replay_runs_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduled_replay_runs
    ADD CONSTRAINT scheduled_replay_runs_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES public.replay_schedules(id) ON DELETE CASCADE;


--
-- Name: schema_validation_metrics schema_validation_metrics_contract_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_validation_metrics
    ADD CONSTRAINT schema_validation_metrics_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contract_schemas(contract_id) ON DELETE CASCADE;


--
-- Name: slack_integrations slack_integrations_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_integrations
    ADD CONSTRAINT slack_integrations_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: slack_messages slack_messages_slack_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_messages
    ADD CONSTRAINT slack_messages_slack_integration_id_fkey FOREIGN KEY (slack_integration_id) REFERENCES public.slack_integrations(id) ON DELETE CASCADE;


--
-- Name: slack_user_subscriptions slack_user_subscriptions_slack_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_user_subscriptions
    ADD CONSTRAINT slack_user_subscriptions_slack_integration_id_fkey FOREIGN KEY (slack_integration_id) REFERENCES public.slack_integrations(id) ON DELETE CASCADE;


--
-- Name: subscription_pause_resume_log subscription_pause_resume_log_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_pause_resume_log
    ADD CONSTRAINT subscription_pause_resume_log_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: telegram_integrations telegram_integrations_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_integrations
    ADD CONSTRAINT telegram_integrations_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: telegram_messages telegram_messages_telegram_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_messages
    ADD CONSTRAINT telegram_messages_telegram_integration_id_fkey FOREIGN KEY (telegram_integration_id) REFERENCES public.telegram_integrations(id) ON DELETE CASCADE;


--
-- Name: telegram_user_subscriptions telegram_user_subscriptions_telegram_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_user_subscriptions
    ADD CONSTRAINT telegram_user_subscriptions_telegram_integration_id_fkey FOREIGN KEY (telegram_integration_id) REFERENCES public.telegram_integrations(id) ON DELETE CASCADE;


--
-- Name: template_usage_stats template_usage_stats_webhook_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_usage_stats
    ADD CONSTRAINT template_usage_stats_webhook_template_id_fkey FOREIGN KEY (webhook_template_id) REFERENCES public.webhook_templates(id) ON DELETE CASCADE;


--
-- Name: template_validation_log template_validation_log_webhook_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.template_validation_log
    ADD CONSTRAINT template_validation_log_webhook_template_id_fkey FOREIGN KEY (webhook_template_id) REFERENCES public.webhook_templates(id) ON DELETE CASCADE;


--
-- Name: webhook_templates webhook_templates_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_templates
    ADD CONSTRAINT webhook_templates_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(id) ON DELETE CASCADE;


--
-- Name: events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_access_audit; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_access_audit ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_access_audit tenant_audit_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_audit_isolation ON public.tenant_access_audit USING (((tenant_id IS NULL) OR (current_setting('app.current_tenant_id'::text, true) = ''::text) OR (tenant_id = current_setting('app.current_tenant_id'::text, true)))) WITH CHECK (((tenant_id IS NULL) OR (current_setting('app.current_tenant_id'::text, true) = ''::text) OR (tenant_id = current_setting('app.current_tenant_id'::text, true))));


--
-- Name: events tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.events USING (((tenant_id IS NULL) OR (COALESCE(current_setting('app.current_tenant_id'::text, true), ''::text) = ''::text) OR (tenant_id = current_setting('app.current_tenant_id'::text, true)))) WITH CHECK (((COALESCE(current_setting('app.current_tenant_id'::text, true), ''::text) = ''::text) OR (tenant_id = current_setting('app.current_tenant_id'::text, true))));


--
-- PostgreSQL database dump complete
--

\unrestrict ijKhzTfms6NedSfMFWK7edXoXeB05Xe95RqW3LtMCbk517Ua3Xgi2JY5h3IHnGt

