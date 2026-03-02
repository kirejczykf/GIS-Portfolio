/*
 * Project: Automated Address Integration (ETL)
 * Description: 
 * A spatial ETL process that syncs national address data (PRG) with the internal
 * network inventory. It performs geometric deduplication, assigns cadastral 
 * property IDs (ULDK), and prevents logical conflicts with existing infrastructure.
 *
 * Tech Stack: PostgreSQL, PostGIS (Spatial Joins), CTE
 */

INSERT INTO inventory.network_locations (
    city, street, house_number, parcel_id, 
    adm_code_terc, adm_code_simc, adm_code_ulic, 
    post_code, geom
)
WITH deduplicated_prg AS (
    -- Step 1: Ingest and deduplicate raw external data (National Register)
    -- Filtering out specific regions based on TERC codes
    SELECT 
        MIN(id) as id, 
        geom, terc, postal_code, simc, city, ulic, street, house_number
    FROM 
        raw_data.national_prg_import
    WHERE 
        terc NOT ILIKE ALL (ARRAY['2001%', '2012%', '2009%', '2063%'])
    GROUP BY 
        geom, terc, postal_code, simc, city, ulic, street, house_number
),
spatial_processing AS (
    -- Step 2: Spatial Enrichment
    -- Join with Cadastral Parcels (ULDK) to automatically assign property IDs
    -- using geometric containment logic (ST_Contains)
    SELECT 
        p.*, 
        cad.id AS parcel_internal_id, 
        cad.parcel_no, 
        cad.terc_code AS cad_terc,
        p.geom AS geom_loc
    FROM 
        deduplicated_prg p
    LEFT JOIN 
        geography.cadastral_parcels cad ON ST_Contains(cad.geom, p.geom)
)
-- Step 3: Final Selection & Exclusion Logic
SELECT 
    sp.city, 
    sp.street, 
    sp.house_number, 
    sp.parcel_no, 
    sp.terc, 
    sp.simc, 
    sp.ulic, 
    sp.postal_code, 
    ST_SetSRID(sp.geom_loc, 2180) -- Enforce EPSG:2180 (Poland CS92)
FROM 
    spatial_processing sp
-- Spatial Anti-Join: Exclude points that overlap with existing network nodes
LEFT JOIN inventory.network_locations existing_loc 
    ON ST_Contains(sp.geom, ST_SetSRID(existing_loc.geom, 2180))
-- Spatial Anti-Join: Exclude points inside existing building footprints
LEFT JOIN geography.building_outlines bdot 
    ON ST_Contains(bdot.geom, sp.geom_loc)
LEFT JOIN inventory.network_locations existing_building_loc 
    ON ST_Contains(bdot.geom, ST_SetSRID(existing_building_loc.geom, 2180))
-- Reference Dictionary Join for administrative validation
LEFT JOIN (
    SELECT DISTINCT simc, terc, ulic
    FROM inventory.network_locations
    WHERE simc IS NOT NULL AND base_id IS NULL
) ref_codes ON sp.simc = ref_codes.simc AND sp.terc = ref_codes.terc
WHERE 
    existing_loc.id IS NULL 
    AND existing_building_loc.id IS NULL
GROUP BY 
    sp.city, sp.street, sp.house_number, sp.parcel_no, sp.terc, 
    sp.simc, sp.ulic, sp.postal_code, sp.geom_loc, ref_codes.terc;
