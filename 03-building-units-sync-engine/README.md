# 03 — Event-Driven Building Unit Provisioning & Synchronization Engine

## Business Problem
In FTTH sales and network planning (homes-passed / HP tracking), multi-dwelling buildings store aggregate unit counts (`residential_units`, `commercial_units`) on the parent building point (`inventory.network_locations`), while CRM contracting and splice allocation require **individual premise records** (`1..N` and `C1..CN`) in `inventory.building_units`.

Maintaining hundreds of thousands of unit rows manually led to mismatches whenever field audits adjusted building capacities — while naive `DELETE + INSERT` regeneration risked wiping out units already tied to active subscriber contracts or custom numbering (`1A`, `U2`, etc.).

## Engineering Solution
Designed an event-driven PL/pgSQL synchronization engine (`inventory.fn_sync_building_units`) triggered automatically on `AFTER INSERT` and conditional `AFTER UPDATE`:

- **Set-Based Provisioning via `generate_series`:** Appends missing residential (`1..N`) and commercial (`C1..CN`) units in a single set-based `INSERT ... SELECT` starting from the highest existing numeric suffix (`regexp_replace(unit_number, '\D', '', 'g')`).
- **Non-Destructive Pruning with Lock Guards:** When a building's unit count is reduced, a `WITH units_to_prune` CTE deletes surplus units from highest number downwards **only where `is_locked = false AND is_manual = false`**, using `GET DIAGNOSTICS ... ROW_COUNT` to warn operators if locked subscriber units prevented full reduction.
- **Runaway-Input Circuit Breaker:** Caps automatic generation at `c_max_units = 10000` per building so accidental form typos (e.g., typing a 5-digit ID into the apartment count field) cannot stall the database.
- **Explicit Foreign-Key Indexing:** Creates dedicated B-tree indexes (`idx_building_units_location_id`, `idx_building_units_location_type`) alongside `ON UPDATE CASCADE ON DELETE RESTRICT`.
- **Conditional Trigger Execution:** Uses `AFTER UPDATE OF residential_units, commercial_units ... WHEN (OLD.* IS DISTINCT FROM NEW.*)` so geometry or address edits never invoke unit synchronization.
- **Transactional Rollback Test Suite:** Includes `BEGIN ... ROLLBACK` test scenarios validating provisioning, expansion, and lock-protected pruning safely against realistic schemas.

## File
- [`building_units_sync.sql`](./building_units_sync.sql) — DDL constraints, indexes, PL/pgSQL sync engine, conditional triggers, and transactional test suite.
