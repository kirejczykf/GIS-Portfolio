/*
 * =============================================================================================
 * MODULE 05: Database Performance Tuning, Dynamic Log Retention & pg_cron Scheduling
 * =============================================================================================
 * Target Dialect : PostgreSQL 9.6 -> 16 Compatible (PL/pgSQL + pg_cron)
 *
 * Overview:
 * Production DBA maintenance toolkit addressing multi-million-row operational audit bloat and
 * automated materialized-view refresh orchestration:
 *   1. B-tree indexing on an unindexed 4,086,000+ row materialized-view refresh log table,
 *      cutting count/range-filter queries from statement timeouts down to ~2 seconds.
 *   2. Reusable, SQL-injection-safe dynamic retention function (`admin.fn_cleanup_old_logs`)
 *      using `format('%I.%I ... %L')` and `RETURNS void` (chosen deliberately over PG 11+
 *      `PROCEDURE` syntax to maintain compatibility across legacy PG 9.x and modern PG 16 nodes).
 *   3. Differentiated `pg_cron` schedules on PostgreSQL 16 (5-minute business-hours refreshes
 *      vs. hourly overnight refreshes + nightly 03:00 retention cleanup).
 * =============================================================================================
 */

-- ---------------------------------------------------------------------------------------------
-- 1. Indexing Multi-Million-Row Operational Audit Table (4M+ Rows)
-- ---------------------------------------------------------------------------------------------
-- Previously, `admin.matview_refresh_log` carried only a primary-key index on `(id)`, forcing
-- full sequential scans on timestamp range queries and retention deletes.
CREATE INDEX IF NOT EXISTS idx_matview_refresh_log_start_time
    ON admin.matview_refresh_log USING btree (start_refresh_time);


-- ---------------------------------------------------------------------------------------------
-- 2. Universal SQL-Injection-Safe Log Retention Function (PG 9.x – PG 16+ Compatible)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION admin.fn_cleanup_old_logs(
    p_schema_name        text,
    p_table_name         text,
    p_date_column        text,
    p_retention_interval interval DEFAULT INTERVAL '1 month'
)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_sql          text;
    v_deleted_rows bigint;
BEGIN
    -- %I safely quotes SQL identifiers (schema, table, column); %L safely quotes literal interval
    v_sql := format(
        'DELETE FROM %I.%I WHERE %I < NOW() - %L::interval',
        p_schema_name,
        p_table_name,
        p_date_column,
        p_retention_interval
    );

    EXECUTE v_sql;
    GET DIAGNOSTICS v_deleted_rows = ROW_COUNT;

    RAISE NOTICE 'Retention cleanup on %.%: deleted % rows older than %.',
        p_schema_name, p_table_name, v_deleted_rows, p_retention_interval;
END;
$function$;

COMMENT ON FUNCTION admin.fn_cleanup_old_logs(text, text, text, interval) IS
    'Generic SQL-injection-safe retention cleanup function compatible with PostgreSQL 9.x through 16+.';

-- Sample invocations across different schemas and retention windows:
-- SELECT admin.fn_cleanup_old_logs('admin', 'matview_refresh_log', 'start_refresh_time');
-- SELECT admin.fn_cleanup_old_logs('public', 'application_audit_logs', 'created_at', INTERVAL '3 months');


-- ---------------------------------------------------------------------------------------------
-- 3. Spatial Materialized View & Index Example for Field Operations
-- ---------------------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS ops.mv_historical_crew_work_orders AS
SELECT
    row_number() OVER (ORDER BY wo.closed_at DESC, wo.work_order_id)::integer AS mv_id,
    wo.work_order_id,
    wo.work_order_title,
    wo.work_type,
    wo.assigned_crew_code,
    wo.closed_at,
    wo.location_id,
    ST_SetSRID(wo.geom, 2180)::geometry(Point, 2180) AS geom
FROM ops.installation_work_orders wo
WHERE wo.geom IS NOT NULL
  AND wo.status = 'COMPLETED'
WITH DATA;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_hist_crew_wo_id
    ON ops.mv_historical_crew_work_orders (mv_id);

CREATE INDEX IF NOT EXISTS idx_mv_hist_crew_wo_geom
    ON ops.mv_historical_crew_work_orders USING GIST (geom);

CREATE INDEX IF NOT EXISTS idx_mv_hist_crew_wo_crew_code
    ON ops.mv_historical_crew_work_orders (assigned_crew_code);


-- ---------------------------------------------------------------------------------------------
-- 4. Automated Scheduling via pg_cron (PostgreSQL 16 Target Environment)
-- ---------------------------------------------------------------------------------------------
-- Business hours (Mon–Fri, 08:00–16:59): high-frequency refresh every 5 minutes for dispatchers
SELECT cron.schedule_in_database(
    'refresh_crew_work_orders_business_hours',
    '*/5 8-16 * * 1-5',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY ops.mv_historical_crew_work_orders;',
    'gis_inventory'
);

-- Off-hours & weekends: lightweight hourly refresh to minimize I/O contention
SELECT cron.schedule_in_database(
    'refresh_crew_work_orders_off_hours',
    '0 17-23,0-7 * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY ops.mv_historical_crew_work_orders;',
    'gis_inventory'
);

-- Nightly retention window (03:00 AM): prune materialized-view refresh logs older than 1 month
SELECT cron.schedule_in_database(
    'nightly_matview_log_retention',
    '0 3 * * *',
    $cron$SELECT admin.fn_cleanup_old_logs('admin', 'matview_refresh_log', 'start_refresh_time', INTERVAL '1 month');$cron$,
    'gis_inventory'
);

-- Operational audit query: inspect 10 most recent pg_cron job executions
-- SELECT jobid, jobname, database, status, start_time, end_time, return_message
-- FROM cron.job_run_details
-- ORDER BY start_time DESC
-- LIMIT 10;
