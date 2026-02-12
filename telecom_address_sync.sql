INSERT INTO inventory.network_locations (
    city, 
    street, 
    house_number, 
    parcel_id, 
    adm_code_terc, 
    adm_code_simc, 
    adm_code_ulic, 
    post_code, 
    geom
)
WITH deduplicated_prg AS (
    -- Deduplicating input addresses and filtering out specific regions
    SELECT 
        MIN(id) as id, 
        geom, 
        terc, 
        postal_code, 
        simc, 
        city, 
        ulic, 
        street, 
        house_number
    FROM raw_data.national_prg_import
    WHERE terc NOT ILIKE ALL (ARRAY['2001%', '2012%', '2009%', '2063%'])
    GROUP BY geom, terc, postal_code, simc, city, ulic, street, house_number
),
spatial_processing AS (
    -- Joining with Cadastral Parcels (ULDK) to get property IDs
    SELECT 
        p.*, 
        cad.id AS parcel_internal_id, 
        cad.parcel_no, 
        cad.terc_code AS cad_terc,
        p.geom AS geom_loc
    FROM deduplicated_prg p
    LEFT JOIN geography.cadastral_parcels cad ON ST_Contains(cad.geom, p.geom)
)
SELECT 
    sp.city, 
    sp.street, 
    sp.house_number, 
    sp.parcel_no, 
    sp.terc, 
    sp.simc, 
    sp.ulic, 
    sp.postal_code, 
    ST_SetSRID(sp.geom_loc, 2180) -- Ensuring correct EPSG:2180 (Poland CS92)
FROM spatial_processing sp
-- Logic: Exclude points that already exist in our inventory (based on parcel or building footprint)
LEFT JOIN inventory.network_locations existing_loc 
    ON ST_Contains(sp.geom, ST_SetSRID(existing_loc.geom, 2180))
LEFT JOIN geography.building_outlines bdot 
    ON ST_Contains(bdot.geom, sp.geom_loc)
LEFT JOIN inventory.network_locations existing_building_loc 
    ON ST_Contains(bdot.geom, ST_SetSRID(existing_building_loc.geom, 2180))
-- Joining with reference dictionary for administrative codes
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
