# 05 — Database Performance Tuning, Dynamic Log Retention & `pg_cron` Orchestration

## Business Problem
In a high-concurrency spatial database serving 100+ users and frequent materialized-view refreshes:
1. An unindexed operational log table (`admin.matview_refresh_log`) accumulated **4,086,000+ rows**, causing administrative range queries and cleanup attempts to stall on full sequential scans.
2. Multiple schemas required periodic log retention with varying time windows (`1 month` vs. `3 months`), while the server fleet spanned **legacy PostgreSQL 9.x** instances (lacking `CREATE PROCEDURE`) and **PostgreSQL 16** instances running `pg_cron`.
3. Operational WebGIS layers needed near-real-time updates during dispatcher work hours (`08:00–16:00`) without wasting server I/O overnight.

## Engineering Solution
- **Targeted B-Tree Indexing:** Added `idx_matview_refresh_log_start_time` on `(start_refresh_time)`, reducing diagnostic queries and timestamp range deletes on the 4M+ row table down to **~2 seconds**.
- **SQL-Injection-Safe Dynamic Retention (`admin.fn_cleanup_old_logs`):** Parameterizes schema, table, date column, and retention interval via `format('DELETE FROM %I.%I WHERE %I < NOW() - %L::interval', ...)` with `GET DIAGNOSTICS ... ROW_COUNT` logging. Implemented deliberately as `RETURNS void` rather than `PROCEDURE` so the exact same artifact deploys cleanly on both **PostgreSQL 9.x** and **PostgreSQL 16**.
- **Spatial Materialized View + `CONCURRENTLY` Refresh Readiness:** Pairs a unique B-tree index (`mv_id`) with a `GiST` geometry index (`EPSG:2180`) so `REFRESH MATERIALIZED VIEW CONCURRENTLY` never blocks live QGIS/LizMap map rendering.
- **Split Day/Night `pg_cron` Schedules:** Uses `cron.schedule_in_database` to run 5-minute refreshes during business hours (`*/5 8-16 * * 1-5`), hourly refreshes off-hours, and automated log pruning nightly at `03:00`.

## File
- [`log_retention_and_cron.sql`](./log_retention_and_cron.sql) — B-tree/GiST indexing, dynamic PL/pgSQL retention function, materialized view DDL, and `pg_cron` schedules.
