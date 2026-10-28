/*
 * =============================================================================================
 * MODULE 04B: Cadastral Parcel Refresh & Subdivision Lineage Tracking ETL (ULDK / EGiB)
 * =============================================================================================
 * Target Dialect : PostgreSQL 14+ / PostGIS 3.x (CRS: EPSG:2180 — PUWG 1992)
 *
 * Overview:
 * Periodic cadastral synchronization workflow updating hundreds of thousands of EGiB/ULDK
 * parcel polygons without breaking dependent database views/permissions or losing historical
 * traceability when parcels are split or merged:
 *   1. Standardizes TERYT hierarchy attributes (`terc`, `county`, `municipality`, `district`,
 *      `parcel_number`) parsed from full national parcel identifiers (`WWPPGG_R.OOOO.NR`).
 *   2. Isolates retired vs. newly created parcels via relational anti-joins.
 *   3. Maps historical lineage (`old_parcel_id -> new_parcel_id`) using GiST-indexed spatial
 *      intersection on an inward-buffered polygon (`ST_Buffer(old.geom, -1.0)`), eliminating
 *      false-positive matches along shared neighboring parcel boundaries.
 *   4. Refreshes the production cadastral table in-place (preserving RBAC grants and dependent
 *      views) and cascades updated parcel numbers to `inventory.network_locations`.
 * =============================================================================================
 */

-- ---------------------------------------------------------------------------------------------
-- 1. Enrich Staged Cadastral Snapshot with Parsed TERYT Administrative Attributes
-- ---------------------------------------------------------------------------------------------
ALTER TABLE staging.cadastral_parcels_import
    ADD COLUMN IF NOT EXISTS terc           VARCHAR(7),
    ADD COLUMN IF NOT EXISTS county_name    TEXT,
    ADD COLUMN IF NOT EXISTS municipality   TEXT,
    ADD COLUMN IF NOT EXISTS district_code  TEXT,
    ADD COLUMN IF NOT EXISTS parcel_number  TEXT,
    ADD COLUMN IF NOT EXISTS land_use_type  TEXT,
    ADD COLUMN IF NOT EXISTS ownership_type TEXT;

-- Parse TERYT prefix, cadastral district, and trailing parcel number in a single table pass
UPDATE staging.cadastral_parcels_import imp
SET
    terc          = left(imp.full_parcel_id, 6),
    district_code = split_part(imp.full_parcel_id, '.', 2),
    parcel_number = reverse(split_part(reverse(imp.full_parcel_id), '.', 1)),
    county_name   = cnt.county_name,
    municipality  = mun.municipality_name
FROM staging.cadastral_parcels_import src
LEFT JOIN cadastre.counties cnt
    ON left(cnt.jpt_code, 4) = left(src.full_parcel_id, 4)
LEFT JOIN cadastre.municipalities mun
    ON left(mun.jpt_code, 6) = left(src.full_parcel_id, 6)
WHERE imp.full_parcel_id = src.full_parcel_id
  AND imp.full_parcel_id IS NOT NULL;


-- ---------------------------------------------------------------------------------------------
-- 2. Isolate Retired (Split/Merged) vs. Newly Created Parcels & Build GiST Indexes
-- ---------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS staging.parcels_retired_delta;
CREATE TABLE staging.parcels_retired_delta AS
SELECT
    old_p.id             AS legacy_internal_id,
    old_p.full_parcel_id AS old_parcel_id,
    old_p.geom,
    old_p.land_use_type,
    old_p.ownership_type
FROM cadastre.cadastral_parcels old_p
LEFT JOIN staging.cadastral_parcels_import new_p
    ON new_p.terc = old_p.terc
   AND new_p.district_code = old_p.district_code
   AND new_p.parcel_number = old_p.parcel_number
WHERE new_p.full_parcel_id IS NULL;

DROP TABLE IF EXISTS staging.parcels_added_delta;
CREATE TABLE staging.parcels_added_delta AS
SELECT
    new_p.full_parcel_id AS new_parcel_id,
    ST_SetSRID(new_p.geom, 2180) AS geom
FROM staging.cadastral_parcels_import new_p
LEFT JOIN cadastre.cadastral_parcels old_p
    ON new_p.terc = old_p.terc
   AND new_p.district_code = old_p.district_code
   AND new_p.parcel_number = old_p.parcel_number
WHERE old_p.full_parcel_id IS NULL;

-- Essential GiST indexes — reduces spatial lineage join from hours to seconds
CREATE INDEX idx_parcels_retired_delta_geom
    ON staging.parcels_retired_delta USING GIST (geom);

CREATE INDEX idx_parcels_added_delta_geom
    ON staging.parcels_added_delta USING GIST (geom);


-- ---------------------------------------------------------------------------------------------
-- 3. Record Parcel Subdivision / Merge Lineage Using Negative Inward Buffer (-1.0 m)
-- ---------------------------------------------------------------------------------------------
-- Why ST_Buffer(geom, -1.0)?
-- Adjacent parcels touch along shared boundary edges. Shrinking the retired polygon inward by
-- 1 meter ensures ST_Intersects matches ONLY genuine interior successors (subdivided/merged plots).
INSERT INTO cadastre.retired_parcels_lineage (
    legacy_internal_id,
    old_parcel_id,
    new_parcel_id,
    geom,
    retirement_year_month
)
SELECT
    ret.legacy_internal_id,
    ret.old_parcel_id,
    add_p.new_parcel_id,
    ret.geom,
    to_char(CURRENT_DATE, 'YYYY-MM') AS retirement_year_month
FROM staging.parcels_retired_delta ret
JOIN staging.parcels_added_delta add_p
    ON ST_Intersects(ST_Buffer(ret.geom, -1.0), add_p.geom)
WHERE NOT EXISTS (
    SELECT 1
    FROM cadastre.retired_parcels_lineage target
    WHERE target.old_parcel_id = ret.old_parcel_id
      AND target.new_parcel_id = add_p.new_parcel_id
);


-- ---------------------------------------------------------------------------------------------
-- 4. Permission-Preserving Production Swap & Downstream Network Inventory Sync
-- ---------------------------------------------------------------------------------------------
BEGIN;

    -- Create point-in-time backup snapshot before refreshing production table
    DROP TABLE IF EXISTS cadastre.cadastral_parcels_prev_backup;
    CREATE TABLE cadastre.cadastral_parcels_prev_backup AS
    SELECT * FROM cadastre.cadastral_parcels;

    -- Truncate/delete rows in-place rather than DROP TABLE so dependent views & RBAC grants survive
    DELETE FROM cadastre.cadastral_parcels WHERE id IS NOT NULL;

    INSERT INTO cadastre.cadastral_parcels (
        id, geom, full_parcel_id, terc, parcel_number,
        county_name, municipality, district_code, land_use_type, ownership_type
    )
    SELECT
        id, ST_SetSRID(geom, 2180), full_parcel_id, terc, parcel_number,
        county_name, municipality, district_code, land_use_type, ownership_type
    FROM staging.cadastral_parcels_import;

    -- Propagate updated parcel numbers to active network locations affected by subdivisions
    UPDATE inventory.network_locations loc
    SET parcel_number = sub.new_parcel_number
    FROM (
        SELECT
            l.id,
            cp.parcel_number AS new_parcel_number
        FROM inventory.network_locations l
        JOIN cadastre.cadastral_parcels cp
            ON ST_Within(ST_SetSRID(l.geom, 2180), cp.geom)
        WHERE l.merged_into_id IS NULL
          AND l.parcel_number IS DISTINCT FROM cp.parcel_number
    ) sub
    WHERE sub.id = loc.id;

COMMIT;

-- Clean up temporary delta staging tables
DROP TABLE IF EXISTS staging.parcels_retired_delta;
DROP TABLE IF EXISTS staging.parcels_added_delta;
