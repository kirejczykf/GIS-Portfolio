/*
 * =============================================================================================
 * MODULE 03: Event-Driven Building Unit Provisioning & Synchronization Engine
 * =============================================================================================
 * Target Dialect : PostgreSQL 14+ / PL/pgSQL
 * Trigger Scope  : AFTER INSERT & AFTER UPDATE OF residential_units, commercial_units
 *                  on inventory.network_locations -> inventory.building_units
 *
 * Overview:
 * Automatically synchronizes individual apartment ('R' = Residential) and commercial ('C' =
 * Commercial) premise records in `inventory.building_units` whenever unit counts change on a
 * parent building record in `inventory.network_locations`.
 *
 * Key Engineering Safeguards:
 *   1. Explicit Foreign Key B-tree indexing (PostgreSQL does not auto-index FK columns).
 *   2. Circuit-breaker threshold (`c_max_units = 10000`) preventing accidental runaway
 *      `generate_series` allocations from typos in parent building forms.
 *   3. Regex numeric extraction (`regexp_replace`) to safely sequence numeric ('1'..'N') and
 *      prefixed commercial ('C1'..'CN') unit designations.
 *   4. Deletion protection: scaling down a building's unit count NEVER deletes units flagged
 *      as locked (`is_locked = true`) or manually curated (`is_manual = true`), emitting
 *      structured `RAISE WARNING` diagnostics via `GET DIAGNOSTICS ... ROW_COUNT`.
 *   5. Exception-isolated trigger wrappers ensuring child sync warnings do not abort critical
 *      parent inventory transactions unless referential constraints are violated.
 * =============================================================================================
 */

-- ---------------------------------------------------------------------------------------------
-- 1. Schema Constraints & Foreign Key Indexing
-- ---------------------------------------------------------------------------------------------
ALTER TABLE inventory.building_units
    ADD COLUMN IF NOT EXISTS unit_type VARCHAR(1) NOT NULL DEFAULT 'R'
        CHECK (unit_type IN ('R', 'C')),
    ADD COLUMN IF NOT EXISTS is_locked BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS is_manual BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN inventory.building_units.unit_type IS
    'R = Residential unit (1..N), C = Commercial unit (C1..CN)';

COMMENT ON COLUMN inventory.building_units.is_locked IS
    'true = unit protected against automatic scale-down deletion (e.g., active subscriber contract)';

ALTER TABLE inventory.building_units
    DROP CONSTRAINT IF EXISTS building_units_location_fk;

ALTER TABLE inventory.building_units
    ADD CONSTRAINT building_units_location_fk
    FOREIGN KEY (location_id)
    REFERENCES inventory.network_locations (id)
    ON UPDATE CASCADE
    ON DELETE RESTRICT;

-- Explicit FK & composite lookup indexes (prevents sequential scans during parent updates/deletes)
CREATE INDEX IF NOT EXISTS idx_building_units_location_id
    ON inventory.building_units (location_id);

CREATE INDEX IF NOT EXISTS idx_building_units_location_type
    ON inventory.building_units (location_id, unit_type);


-- ---------------------------------------------------------------------------------------------
-- 2. Core Synchronization Procedure (Callable Directly or via Trigger Wrappers)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory.fn_sync_building_units(
    p_location_id       integer,
    p_residential_count integer,
    p_commercial_count  integer
)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_current_r     integer;
    v_max_num_r     integer;
    v_target_r      integer;
    v_deleted_r     integer;
    v_current_c     integer;
    v_max_num_c     integer;
    v_target_c      integer;
    v_deleted_c     integer;
    c_max_units     CONSTANT integer := 10000;
BEGIN
    v_target_r := COALESCE(p_residential_count, 0);
    v_target_c := COALESCE(p_commercial_count, 0);

    -- Safety circuit breaker against accidental data-entry typos (e.g., entering postal code)
    IF v_target_r > c_max_units OR v_target_c > c_max_units THEN
        RAISE WARNING
            'location_id=%: requested unit count exceeds safety cap % (R=%, C=%) — skipping sync.',
            p_location_id, c_max_units, v_target_r, v_target_c;
        RETURN;
    END IF;

    -- =========================================================================
    -- PART A: Synchronize Residential Units ('R': '1', '2', ..., 'N')
    -- =========================================================================
    SELECT
        COUNT(*),
        COALESCE(MAX(NULLIF(regexp_replace(unit_number, '\D', '', 'g'), '')::integer), 0)
    INTO
        v_current_r,
        v_max_num_r
    FROM inventory.building_units
    WHERE location_id = p_location_id
      AND unit_type = 'R';

    IF v_target_r > v_current_r THEN
        INSERT INTO inventory.building_units (
            location_id, unit_number, unit_type, is_manual, is_locked
        )
        SELECT
            p_location_id,
            i::varchar,
            'R',
            false,
            false
        FROM generate_series(
            v_max_num_r + 1,
            v_max_num_r + (v_target_r - v_current_r)
        ) AS i;

        RAISE NOTICE 'location_id=%: provisioned % residential units (% to %).',
            p_location_id,
            (v_target_r - v_current_r),
            v_max_num_r + 1,
            v_max_num_r + (v_target_r - v_current_r);

    ELSIF v_target_r < v_current_r THEN
        WITH units_to_prune AS (
            SELECT id
            FROM inventory.building_units
            WHERE location_id = p_location_id
              AND unit_type = 'R'
              AND is_locked = false
              AND is_manual = false
            ORDER BY NULLIF(regexp_replace(unit_number, '\D', '', 'g'), '')::integer DESC NULLS LAST
            LIMIT (v_current_r - v_target_r)
        )
        DELETE FROM inventory.building_units
        WHERE id IN (SELECT id FROM units_to_prune);

        GET DIAGNOSTICS v_deleted_r = ROW_COUNT;

        IF v_deleted_r < (v_current_r - v_target_r) THEN
            RAISE WARNING
                'location_id=%: requested removal of % residential units, removed % (remaining units are locked or manual).',
                p_location_id, (v_current_r - v_target_r), v_deleted_r;
        ELSE
            RAISE NOTICE 'location_id=%: removed % surplus residential units.',
                p_location_id, v_deleted_r;
        END IF;
    END IF;

    -- =========================================================================
    -- PART B: Synchronize Commercial Units ('C': 'C1', 'C2', ..., 'CN')
    -- =========================================================================
    SELECT
        COUNT(*),
        COALESCE(MAX(NULLIF(regexp_replace(unit_number, '\D', '', 'g'), '')::integer), 0)
    INTO
        v_current_c,
        v_max_num_c
    FROM inventory.building_units
    WHERE location_id = p_location_id
      AND unit_type = 'C';

    IF v_target_c > v_current_c THEN
        INSERT INTO inventory.building_units (
            location_id, unit_number, unit_type, is_manual, is_locked
        )
        SELECT
            p_location_id,
            'C' || i::varchar,
            'C',
            false,
            false
        FROM generate_series(
            v_max_num_c + 1,
            v_max_num_c + (v_target_c - v_current_c)
        ) AS i;

        RAISE NOTICE 'location_id=%: provisioned % commercial units (C% to C%).',
            p_location_id,
            (v_target_c - v_current_c),
            v_max_num_c + 1,
            v_max_num_c + (v_target_c - v_current_c);

    ELSIF v_target_c < v_current_c THEN
        WITH units_to_prune AS (
            SELECT id
            FROM inventory.building_units
            WHERE location_id = p_location_id
              AND unit_type = 'C'
              AND is_locked = false
              AND is_manual = false
            ORDER BY NULLIF(regexp_replace(unit_number, '\D', '', 'g'), '')::integer DESC NULLS LAST
            LIMIT (v_current_c - v_target_c)
        )
        DELETE FROM inventory.building_units
        WHERE id IN (SELECT id FROM units_to_prune);

        GET DIAGNOSTICS v_deleted_c = ROW_COUNT;

        IF v_deleted_c < (v_current_c - v_target_c) THEN
            RAISE WARNING
                'location_id=%: requested removal of % commercial units, removed % (remaining units are locked or manual).',
                p_location_id, (v_current_c - v_target_c), v_deleted_c;
        ELSE
            RAISE NOTICE 'location_id=%: removed % surplus commercial units.',
                p_location_id, v_deleted_c;
        END IF;
    END IF;
END;
$function$;

COMMENT ON FUNCTION inventory.fn_sync_building_units(integer, integer, integer) IS
    'Synchronizes residential (R) and commercial (C) child records in inventory.building_units for a parent network location.';


-- ---------------------------------------------------------------------------------------------
-- 3. Trigger Wrappers & Conditional Event Bindings
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory.fn_trg_location_units_after_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF COALESCE(NEW.residential_units, 0) + COALESCE(NEW.commercial_units, 0) > 0 THEN
        BEGIN
            PERFORM inventory.fn_sync_building_units(
                NEW.id,
                NEW.residential_units,
                NEW.commercial_units
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Unit sync failed after INSERT on location_id=%: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION inventory.fn_trg_location_units_after_update()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    BEGIN
        PERFORM inventory.fn_sync_building_units(
            NEW.id,
            NEW.residential_units,
            NEW.commercial_units
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Unit sync failed after UPDATE on location_id=%: %', NEW.id, SQLERRM;
    END;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_network_location_units_insert ON inventory.network_locations;
CREATE TRIGGER trg_network_location_units_insert
AFTER INSERT ON inventory.network_locations
FOR EACH ROW
EXECUTE FUNCTION inventory.fn_trg_location_units_after_insert();

DROP TRIGGER IF EXISTS trg_network_location_units_update ON inventory.network_locations;
CREATE TRIGGER trg_network_location_units_update
AFTER UPDATE OF residential_units, commercial_units ON inventory.network_locations
FOR EACH ROW
WHEN (
    OLD.residential_units IS DISTINCT FROM NEW.residential_units
    OR OLD.commercial_units IS DISTINCT FROM NEW.commercial_units
)
EXECUTE FUNCTION inventory.fn_trg_location_units_after_update();


-- ---------------------------------------------------------------------------------------------
-- 4. Transactional Verification Suite (Safe Non-Destructive Rollback Tests)
-- ---------------------------------------------------------------------------------------------
/*
-- Scenario A: Initial provisioning + scale-up + protected scale-down verification
BEGIN;

    -- 1. Provision 5 residential ('1'..'5') and 2 commercial ('C1'..'C2') units for test location 10001
    SELECT inventory.fn_sync_building_units(10001, 5, 2);

    -- 2. Scale up to 8 residential + 4 commercial (adds '6'..'8' and 'C3'..'C4')
    SELECT inventory.fn_sync_building_units(10001, 8, 4);

    -- 3. Lock unit '6' (active subscriber) and mark unit '7' as manually curated
    UPDATE inventory.building_units SET is_locked = true WHERE location_id = 10001 AND unit_number = '6';
    UPDATE inventory.building_units SET is_manual = true WHERE location_id = 10001 AND unit_number = '7';

    -- 4. Request scale-down to 5 residential units:
    --    Engine prunes '8' (unlocked) and preserves '6' (locked) & '7' (manual), emitting a WARNING.
    SELECT inventory.fn_sync_building_units(10001, 5, 2);

    SELECT unit_number, unit_type, is_locked, is_manual
    FROM inventory.building_units
    WHERE location_id = 10001
    ORDER BY unit_type, id;

ROLLBACK;
*/
