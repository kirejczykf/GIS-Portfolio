/*
 * =============================================================================================
 * MODULE 01: Real-Time Spatial Address Validation, TERYT Enrichment & Sub-Addressing Trigger
 * =============================================================================================
 * Target Dialect : PostgreSQL 14+ / PostGIS 3.x (CRS: EPSG:2180 — PUWG 1992)
 * Trigger Scope  : BEFORE INSERT OR UPDATE on inventory.network_locations
 *
 * Overview:
 * Enforces address integrity at the database engine level for WebGIS (LizMap) and desktop QGIS
 * editors creating or modifying fiber-optic network address points:
 *   1. Normalizes whitespace and empty strings to NULL across text attributes.
 *   2. Auto-populates 7-digit TERC municipality codes via spatial point-in-polygon lookup
 *      (ST_Intersects against cadastral districts in EPSG:2180).
 *   3. Resolves official SIMC (locality) and ULIC (street) dictionary identifiers, applying
 *      standard '99999' fallback codes for streetless rural localities.
 *   4. Handles unnumbered parcel-only endpoints (house_number IS NULL) by automatically
 *      assigning sequential auxiliary sub-addresses ('A', 'B', 'C', ...) when multiple network
 *      terminations share the same cadastral plot, retroactively labeling the first record 'A'.
 *   5. Blocks duplicate active addresses (ignoring merged/archived records where
 *      merged_into_id IS NOT NULL) using NULL-safe comparisons and SQLSTATE 23505 exceptions.
 * =============================================================================================
 */

-- ---------------------------------------------------------------------------------------------
-- 0. Schema Prerequisites & Constraints (Reference DDL)
-- ---------------------------------------------------------------------------------------------
ALTER TABLE inventory.network_locations
    ADD COLUMN IF NOT EXISTS aux_subaddress VARCHAR(5),
    ADD COLUMN IF NOT EXISTS data_source    TEXT;

ALTER TABLE inventory.network_locations
    DROP CONSTRAINT IF EXISTS chk_aux_subaddress;

ALTER TABLE inventory.network_locations
    ADD CONSTRAINT chk_aux_subaddress
    CHECK (aux_subaddress ~ '^[A-Z]{1,2}$');

-- Spatial index required on cadastral districts for sub-millisecond ST_Intersects lookup
CREATE INDEX IF NOT EXISTS idx_cadastral_districts_geom
    ON cadastre.cadastral_districts USING GIST (geom);

-- Composite B-tree index supporting fast duplicate & parcel sub-address lookups
CREATE INDEX IF NOT EXISTS idx_network_locations_teryt_lookup
    ON inventory.network_locations (simc, left(terc, 7), parcel_number)
    WHERE merged_into_id IS NULL;


-- ---------------------------------------------------------------------------------------------
-- 1. Main Trigger Function: Spatial Enrichment, Parcel Sub-Addressing & Duplicate Guard
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory.fn_validate_and_enrich_location()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_dup_id       bigint;
    v_dup_parcel   text;
    v_display_addr text;
    v_parcel_count integer;
    v_max_letter   varchar(2);
BEGIN
    -- =========================================================================
    -- STEP 1: Input Normalization (trim whitespace, collapse empty strings)
    -- =========================================================================
    NEW.city          := NULLIF(btrim(NEW.city), '');
    NEW.street        := NULLIF(btrim(NEW.street), '');
    NEW.house_number  := NULLIF(btrim(NEW.house_number), '');
    NEW.parcel_number := NULLIF(btrim(NEW.parcel_number), '');

    -- =========================================================================
    -- STEP 2: Automated TERYT Enrichment (INSERT operations only)
    -- =========================================================================
    IF TG_OP = 'INSERT' THEN

        -- 2a. Derive 7-character TERC code spatially from cadastral district polygon
        IF NEW.geom IS NOT NULL AND NEW.terc IS NULL THEN
            SELECT split_part(replace(d.district_code, '_', ''), '.', 1)
            INTO NEW.terc
            FROM cadastre.cadastral_districts d
            WHERE ST_Intersects(
                    d.geom,
                    ST_SetSRID(NEW.geom, 2180)
                  )
            LIMIT 1;
        END IF;

        -- 2b. Resolve SIMC locality identifier from locality name + 7-char TERC prefix
        IF NEW.city IS NOT NULL AND NEW.terc IS NOT NULL AND NEW.simc IS NULL THEN
            SELECT c.simc
            INTO NEW.simc
            FROM reference.teryt_localities c
            WHERE lower(btrim(c.locality_name)) = lower(NEW.city)
              AND left(c.terc, 7) = left(NEW.terc, 7)
            LIMIT 1;
        END IF;

        -- 2c. Resolve ULIC street code from street name + SIMC
        IF NEW.street IS NOT NULL AND NEW.simc IS NOT NULL AND NEW.ulic IS NULL THEN
            SELECT s.ulic
            INTO NEW.ulic
            FROM reference.teryt_streets s
            WHERE lower(btrim(s.street_name)) = lower(NEW.street)
              AND s.simc = NEW.simc
            LIMIT 1;
        END IF;

        -- 2d. Rural fallback: assign standard ULIC = '99999' when locality has no streets
        IF NEW.street IS NULL AND NEW.ulic IS NULL AND NEW.simc IS NOT NULL THEN
            IF NOT EXISTS (
                SELECT 1
                FROM reference.teryt_streets s
                WHERE s.simc = NEW.simc
            ) THEN
                NEW.ulic   := '99999';
                NEW.street := NULL;
            END IF;
        END IF;

    END IF;

    -- =========================================================================
    -- STEP 3: Unnumbered Parcel Endpoints & Sequential Sub-Addressing (A, B, C)
    -- =========================================================================
    IF NEW.house_number IS NULL THEN

        IF NEW.parcel_number IS NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '23502',
                MESSAGE = 'Cannot save unnumbered location: parcel_number is required when house_number is NULL.';
        END IF;

        IF NEW.simc IS NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '23502',
                MESSAGE = format(
                    'Cannot save parcel location: missing SIMC code for locality "%s".',
                    coalesce(NEW.city, '(unspecified)')
                );
        END IF;

        IF NEW.terc IS NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '23502',
                MESSAGE = 'Cannot save parcel location: missing TERC code (missing geometry or point outside service coverage).';
        END IF;

        -- Count active unnumbered points already registered on the same cadastral parcel
        SELECT
            COUNT(*),
            MAX(aux_subaddress)
        INTO
            v_parcel_count,
            v_max_letter
        FROM inventory.network_locations
        WHERE parcel_number = NEW.parcel_number
          AND simc = NEW.simc
          AND left(terc, 7) = left(NEW.terc, 7)
          AND house_number IS NULL
          AND merged_into_id IS NULL
          AND (TG_OP = 'INSERT' OR id IS DISTINCT FROM NEW.id);

        -- First point on this parcel -> store cleanly without auxiliary suffix
        IF v_parcel_count = 0 THEN
            RETURN NEW;
        END IF;

        -- Second point arrives while the first has no suffix -> retroactively label first as 'A'
        IF v_parcel_count = 1 AND v_max_letter IS NULL THEN
            UPDATE inventory.network_locations
            SET aux_subaddress = 'A'
            WHERE parcel_number = NEW.parcel_number
              AND simc = NEW.simc
              AND left(terc, 7) = left(NEW.terc, 7)
              AND house_number IS NULL
              AND aux_subaddress IS NULL
              AND merged_into_id IS NULL
              AND (TG_OP = 'INSERT' OR id IS DISTINCT FROM NEW.id);

            v_max_letter := 'A';
        END IF;

        -- Assign next letter suffix ('A' -> 'B' -> 'C' ...)
        IF v_max_letter IS NULL THEN
            NEW.aux_subaddress := 'A';
        ELSIF v_max_letter = 'Z' THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = format(
                    'Auxiliary sub-address limit (A-Z) reached on parcel %s (SIMC %s).',
                    NEW.parcel_number, NEW.simc
                );
        ELSE
            NEW.aux_subaddress := chr(ascii(v_max_letter) + 1);
        END IF;

        RETURN NEW;
    END IF;

    -- =========================================================================
    -- STEP 4: Format Human-Readable Address for Error Diagnostics
    -- =========================================================================
    IF NEW.street IS NULL THEN
        v_display_addr := coalesce(NEW.city, '(unknown locality)') || ' ' || NEW.house_number;
    ELSE
        v_display_addr := coalesce(NEW.city, '(unknown locality)') || ', ' || NEW.street || ' ' || NEW.house_number;
    END IF;

    -- =========================================================================
    -- STEP 5: Active-Inventory Duplicate Guard (INSERT + UPDATE)
    -- =========================================================================
    SELECT
        loc.id,
        NULLIF(btrim(loc.parcel_number), '')
    INTO
        v_dup_id,
        v_dup_parcel
    FROM inventory.network_locations loc
    WHERE loc.id IS DISTINCT FROM NEW.id
      AND loc.merged_into_id IS NULL  -- Ignore historical records merged into another master point
      AND left(loc.terc, 7) IS NOT DISTINCT FROM left(NEW.terc, 7)
      AND loc.simc IS NOT DISTINCT FROM NEW.simc
      AND NULLIF(btrim(loc.house_number), '') IS NOT DISTINCT FROM NEW.house_number
      AND NULLIF(btrim(loc.city), '') IS NOT DISTINCT FROM NEW.city
      AND NULLIF(btrim(loc.street), '') IS NOT DISTINCT FROM NEW.street
    LIMIT 1;

    IF v_dup_id IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '23505',
            MESSAGE = E'DUPLICATE_ADDRESS\n\n'
                || 'An active network location with this address already exists:' || E'\n'
                || v_display_addr || E'\n'
                || 'Parcel: ' || coalesce(v_dup_parcel, '(none)') || E'\n'
                || 'Existing Location ID: ' || v_dup_id || E'\n';
    END IF;

    RETURN NEW;
END;
$function$;


-- ---------------------------------------------------------------------------------------------
-- 2. Provenance Helper Trigger: Default Data Source Tagging on Manual Inserts
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory.fn_set_default_data_source()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.data_source IS NULL THEN
        NEW.data_source := 'manual_entry';
    END IF;
    RETURN NEW;
END;
$function$;


-- ---------------------------------------------------------------------------------------------
-- 3. Trigger Bindings (Scoped Column List Prevents Unnecessary Firing on Non-Address Edits)
-- ---------------------------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_location_validate_and_enrich ON inventory.network_locations;

CREATE TRIGGER trg_location_validate_and_enrich
BEFORE INSERT OR UPDATE OF
    city,
    street,
    house_number,
    parcel_number,
    geom,
    terc,
    simc,
    ulic
ON inventory.network_locations
FOR EACH ROW
EXECUTE FUNCTION inventory.fn_validate_and_enrich_location();

DROP TRIGGER IF EXISTS trg_location_default_source ON inventory.network_locations;

CREATE TRIGGER trg_location_default_source
BEFORE INSERT
ON inventory.network_locations
FOR EACH ROW
EXECUTE FUNCTION inventory.fn_set_default_data_source();
