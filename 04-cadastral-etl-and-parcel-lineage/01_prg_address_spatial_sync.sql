/*
 * =============================================================================================
 * MODULE 04A: National Address Register (PRG) Spatial Synchronization Pipeline
 * =============================================================================================
 * Target Dialect : PostgreSQL 14+ / PostGIS 3.x (CRS: EPSG:2180 — PUWG 1992)
 *
 * Overview:
 * Idempotent spatial ETL query synchronizing newly published address points from Poland's
 * National Official Register of Territorial Division & Addresses (PRG) into the internal
 * telecom inventory (`inventory.network_locations`):
 *   1. Deduplicates raw PRG imports and filters out out-of-footprint TERC regions.
 *   2. Enriches points with cadastral parcel numbers via point-in-polygon join (ST_Contains).
 *   3. Executes dual spatial anti-joins against existing network nodes and BDOT10k building
 *      footprints so already-inventoried buildings never receive duplicate address pins.
 * =============================================================================================
 */

INSERT INTO inventory.network_locations (
    city,
    street,
    house_number,
    parcel_number,
    terc,
    simc,
    ulic,
    postal_code,
    data_source,
    geom
)
WITH deduplicated_prg AS (
    -- Step 1: Ingest & deduplicate raw PRG snapshot within active regional TERC footprint
    SELECT
        MIN(id) AS source_id,
        ST_SetSRID(geom, 2180) AS geom,
        terc,
        postal_code,
        simc,
        city,
        COALESCE(ulic, '99999') AS ulic,
        street,
        house_number
    FROM staging.national_prg_import
    WHERE terc NOT ILIKE ALL (ARRAY['2001%', '2009%', '2012%', '2063%'])
      AND simc IS NOT NULL
    GROUP BY
        geom, terc, postal_code, simc, city, COALESCE(ulic, '99999'), street, house_number
),
parcel_enriched AS (
    -- Step 2: Spatial enrichment against EGiB/ULDK cadastral parcels (GiST-accelerated ST_Contains)
    SELECT
        p.city,
        p.street,
        p.house_number,
        cp.parcel_number,
        p.terc,
        p.simc,
        p.ulic,
        p.postal_code,
        p.geom
    FROM deduplicated_prg p
    LEFT JOIN cadastre.cadastral_parcels cp
        ON ST_Contains(cp.geom, p.geom)
)
-- Step 3: Dual Spatial Anti-Join (exclude points matching existing nodes or occupied buildings)
SELECT
    pe.city,
    pe.street,
    pe.house_number,
    pe.parcel_number,
    pe.terc,
    pe.simc,
    pe.ulic,
    pe.postal_code,
    'prg_spatial_etl' AS data_source,
    pe.geom
FROM parcel_enriched pe
-- Anti-Join A: Direct geometric coincidence with existing active network locations
LEFT JOIN inventory.network_locations existing_pt
    ON existing_pt.merged_into_id IS NULL
   AND ST_DWithin(pe.geom, ST_SetSRID(existing_pt.geom, 2180), 1.0)
-- Anti-Join B: Point falls inside a BDOT10k building footprint that already holds an active node
LEFT JOIN topography.building_footprints bf
    ON ST_Contains(bf.geom, pe.geom)
LEFT JOIN inventory.network_locations existing_bldg_pt
    ON existing_bldg_pt.merged_into_id IS NULL
   AND ST_Contains(bf.geom, ST_SetSRID(existing_bldg_pt.geom, 2180))
WHERE existing_pt.id IS NULL
  AND existing_bldg_pt.id IS NULL
GROUP BY
    pe.city,
    pe.street,
    pe.house_number,
    pe.parcel_number,
    pe.terc,
    pe.simc,
    pe.ulic,
    pe.postal_code,
    pe.geom;
