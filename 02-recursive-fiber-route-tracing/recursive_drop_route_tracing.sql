/*
 * =============================================================================================
 * MODULE 02: Recursive Fiber-Optic Drop-Cable Route Tracing & Parcel Classification Engine
 * =============================================================================================
 * Target Dialect : PostgreSQL 14+ / PostGIS 3.x (CRS: EPSG:2180 — PUWG 1992)
 * Architecture   : 10-Stage CTE Pipeline (WITH RECURSIVE + Topology Clipping + LATERAL Join)
 *
 * Overview:
 * Reconstructs end-to-end subscriber drop-cable routes backwards from the customer's optical
 * network terminal (ONT / wall socket) through intermediate nodes up to the feeding backbone
 * splice closure (defined topologically as a node with degree > 2 optical cables).
 *
 * Key Capabilities:
 *   1. Pre-computes physical node degrees across the optical cable graph.
 *   2. Traverses undirected cable edges backwards using WITH RECURSIVE while preventing
 *      infinite graph loops via visited-cable and visited-node PostgreSQL arrays.
 *   3. Selects the shortest valid topological path per installation work order (DISTINCT ON).
 *   4. Clips drop-cable geometries against BDOT10k building footprints (ST_Difference +
 *      ST_DWithin spatial pre-filter) so cables terminate cleanly at exterior building walls.
 *   5. Merges contiguous segments by infrastructure owner into MultiLineString geometries
 *      and classifies deployment type (Aerial / Underground / Mixed).
 *   6. Cross-references cadastral parcels via LEFT JOIN LATERAL to classify right-of-way vs.
 *      subscriber-plot routing ('Road Right-of-Way', 'Subscriber Parcel', 'Mixed').
 * =============================================================================================
 */

-- ---------------------------------------------------------------------------------------------
-- 0. Target Analytical Layer Sequence Setup
-- ---------------------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS analytics.subscriber_drop_routes_id_seq;

ALTER TABLE analytics.subscriber_drop_routes
    ALTER COLUMN id SET DEFAULT nextval('analytics.subscriber_drop_routes_id_seq');


-- ---------------------------------------------------------------------------------------------
-- 1. Main Recursive Graph & Spatial Processing Pipeline (Batch-Safe Execution)
-- ---------------------------------------------------------------------------------------------
INSERT INTO analytics.subscriber_drop_routes (
    id,
    work_order_id,
    work_order_title,
    geom,
    cable_owner,
    deployment_type,
    parcel_routing_class,
    start_node_code,
    start_node_id,
    end_node_code,
    end_node_id,
    intermediate_nodes,
    intermediate_node_ids,
    cable_designations,
    cable_ids,
    feeding_location_id,
    feeding_address
)
WITH RECURSIVE node_degrees AS (
    -- [STAGE 1] Compute Node Degree Across Physical Optical Graph
    -- Nodes with > 2 connected optical cables represent distribution/backbone splice closures.
    SELECT
        node_id,
        count(*)::integer AS cable_count
    FROM (
        SELECT from_node_id AS node_id FROM telecom.optical_cables
        UNION ALL
        SELECT to_node_id   AS node_id FROM telecom.optical_cables
    ) edges
    WHERE node_id IS NOT NULL
    GROUP BY node_id
),
route_traversal AS (
    -- [STAGE 2A] Anchor Member: Initialize traversal at customer ONT / building termination node
    SELECT
        wo.work_order_id,
        wo.work_order_title,
        ont.upstream_target_node_id AS target_backbone_node_id,
        ont.customer_socket_node_id AS origin_customer_node_id,
        ont.node_label,
        oc.id                       AS cable_id,
        oc.designation              AS cable_designation,
        oc.owner_code               AS cable_owner_code,
        cm.deployment_method        AS cable_deployment_method,
        CASE
            WHEN oc.to_node_id = n.id THEN oc.from_node_id
            ELSE oc.to_node_id
        END                         AS next_upstream_node_id,
        oc.from_node_id,
        oc.to_node_id,
        ST_SetSRID(oc.geom, 2180)   AS geom,
        1                           AS hop_depth,
        ARRAY[oc.id]                AS visited_cables,
        ARRAY[n.id]                 AS visited_nodes,
        ST_SetSRID(n.geom, 2180)    AS origin_point_geom
    FROM (
        -- Incremental anti-join batching: process up to 1,000 unmapped drop installations per run
        SELECT w.*
        FROM ops.installation_work_orders w
        LEFT JOIN analytics.subscriber_drop_routes r
            ON r.work_order_id = w.work_order_id
        WHERE r.work_order_id IS NULL
          AND w.work_order_title ILIKE '%[DROP]%'
        LIMIT 1000
    ) wo
    LEFT JOIN inventory.network_locations loc
        ON loc.id = wo.location_id
    LEFT JOIN telecom.buildings b
        ON b.location_id = loc.id
    LEFT JOIN telecom.network_nodes n
        ON n.structure_id = b.id
    LEFT JOIN telecom.v_subscriber_ont_links ont
        ON ont.customer_socket_node_id = n.id
    JOIN telecom.optical_cables oc
        ON (oc.to_node_id = n.id OR oc.from_node_id = n.id)
    LEFT JOIN telecom.cable_models cm
        ON oc.model_code = cm.model_code

    UNION ALL

    -- [STAGE 2B] Recursive Member: Step upstream along connected cables
    -- Loop prevention via visited arrays; halts upon reaching a distribution node (cable_count > 2)
    SELECT
        prev.work_order_id,
        prev.work_order_title,
        prev.target_backbone_node_id,
        prev.origin_customer_node_id,
        prev.node_label,
        oc_next.id                     AS cable_id,
        oc_next.designation            AS cable_designation,
        oc_next.owner_code             AS cable_owner_code,
        cm_next.deployment_method      AS cable_deployment_method,
        CASE
            WHEN oc_next.to_node_id = prev.next_upstream_node_id THEN oc_next.from_node_id
            ELSE oc_next.to_node_id
        END                            AS next_upstream_node_id,
        oc_next.from_node_id,
        oc_next.to_node_id,
        ST_SetSRID(oc_next.geom, 2180) AS geom,
        prev.hop_depth + 1,
        prev.visited_cables || oc_next.id,
        prev.visited_nodes  || prev.next_upstream_node_id,
        prev.origin_point_geom
    FROM route_traversal prev
    JOIN node_degrees nd
        ON nd.node_id = prev.next_upstream_node_id
    JOIN telecom.optical_cables oc_next
        ON (oc_next.to_node_id = prev.next_upstream_node_id
            OR oc_next.from_node_id = prev.next_upstream_node_id)
    LEFT JOIN telecom.cable_models cm_next
        ON oc_next.model_code = cm_next.model_code
    WHERE NOT (oc_next.id = ANY(prev.visited_cables))
      AND NOT (prev.next_upstream_node_id = ANY(prev.visited_nodes))
      AND nd.cable_count <= 2
      AND prev.next_upstream_node_id IS DISTINCT FROM prev.target_backbone_node_id
      AND prev.next_upstream_node_id IS DISTINCT FROM prev.origin_customer_node_id
),
shortest_paths AS (
    -- [STAGE 3] Shortest Valid Path Selection
    -- Retain the minimum-hop path per work order that reached a backbone node or designated target
    SELECT DISTINCT ON (rt.work_order_id)
        rt.work_order_id,
        rt.visited_cables,
        rt.visited_nodes,
        rt.origin_point_geom
    FROM route_traversal rt
    JOIN node_degrees nd
        ON nd.node_id = rt.next_upstream_node_id
    WHERE nd.cable_count > 2
       OR rt.next_upstream_node_id = rt.target_backbone_node_id
    ORDER BY rt.work_order_id, rt.hop_depth ASC
),
unpacked_cables AS (
    -- [STAGE 4] Unnest Cable ID Arrays into Relational Rows
    SELECT
        sp.work_order_id,
        unnest(sp.visited_cables) AS cable_id
    FROM shortest_paths sp
),
winning_cables AS (
    -- [STAGE 5] Retrieve Technical Metadata & Geometries for Winning Path Segments
    SELECT DISTINCT
        rt.work_order_id,
        rt.cable_id,
        rt.cable_designation,
        rt.cable_owner_code,
        rt.cable_deployment_method,
        rt.geom,
        rt.hop_depth
    FROM route_traversal rt
    JOIN unpacked_cables uc
        ON uc.work_order_id = rt.work_order_id
       AND uc.cable_id = rt.cable_id
),
work_order_metadata AS (
    -- [STAGE 6] Aggregate Intermediate Transit Node IDs & Designations
    SELECT
        rt.work_order_id,
        rt.work_order_title,
        rt.target_backbone_node_id,
        rt.origin_customer_node_id,
        rt.node_label,
        (
            SELECT sp2.origin_point_geom
            FROM shortest_paths sp2
            WHERE sp2.work_order_id = rt.work_order_id
        ) AS start_geom,
        (
            SELECT string_agg(DISTINCT w.node_id::text, ', ')
            FROM (
                SELECT unnest(sp3.visited_nodes) AS node_id
                FROM shortest_paths sp3
                WHERE sp3.work_order_id = rt.work_order_id
            ) w
            WHERE w.node_id IS DISTINCT FROM rt.target_backbone_node_id
              AND w.node_id IS DISTINCT FROM rt.origin_customer_node_id
        ) AS transit_node_ids,
        (
            SELECT string_agg(DISTINCT n_mid.designation, ', ')
            FROM (
                SELECT unnest(sp4.visited_nodes) AS node_id
                FROM shortest_paths sp4
                WHERE sp4.work_order_id = rt.work_order_id
            ) w2
            JOIN telecom.network_nodes n_mid
                ON n_mid.id = w2.node_id
            WHERE w2.node_id IS DISTINCT FROM rt.target_backbone_node_id
              AND w2.node_id IS DISTINCT FROM rt.origin_customer_node_id
        ) AS transit_node_names
    FROM route_traversal rt
    GROUP BY
        rt.work_order_id,
        rt.work_order_title,
        rt.target_backbone_node_id,
        rt.origin_customer_node_id,
        rt.node_label
),
clipped_cables AS (
    -- [STAGE 7] Topological Clipping Against BDOT10k Building Footprints
    -- Trims indoor cable tails using ST_Difference so map lines terminate cleanly at outer walls.
    -- ST_DWithin(..., 100) leverages GiST index bounding boxes to restrict polygon unions locally.
    SELECT
        wc.*,
        COALESCE(
            (
                SELECT ST_Difference(wc.geom, ST_Union(ST_SetSRID(bf.geom, 2180)))
                FROM topography.building_footprints bf
                WHERE ST_DWithin(wm.start_geom, ST_SetSRID(bf.geom, 2180), 100)
                  AND ST_Intersects(wc.geom, ST_SetSRID(bf.geom, 2180))
            ),
            wc.geom
        ) AS clipped_geom
    FROM winning_cables wc
    JOIN work_order_metadata wm
        ON wm.work_order_id = wc.work_order_id
),
owner_segments AS (
    -- [STAGE 8] Consolidate Geometries into MultiLineStrings Grouped by Infrastructure Owner
    SELECT
        cc.work_order_id,
        CASE
            WHEN cc.cable_owner_code = '1' THEN 'Operator_Core'
            WHEN cc.cable_owner_code = '2' THEN 'Regional_Partner'
            WHEN cc.cable_owner_code = '3' THEN 'Subscriber_Drop'
            ELSE 'Other_Infrastructure'
        END AS owner_name,
        ST_Multi(ST_CollectionExtract(ST_Collect(cc.clipped_geom), 2)) AS geom,
        CASE
            WHEN count(DISTINCT cc.cable_deployment_method) > 1 THEN 'Mixed'
            WHEN max(cc.cable_deployment_method) = 'Aerial'      THEN 'Aerial'
            WHEN max(cc.cable_deployment_method) = 'Underground' THEN 'Underground'
            ELSE 'Unspecified'
        END AS deployment_type,
        string_agg(DISTINCT coalesce(cc.cable_designation, 'unnamed'), ', ') AS cable_designations,
        string_agg(DISTINCT cc.cable_id::text, ', ')                         AS cable_ids
    FROM clipped_cables cc
    GROUP BY
        cc.work_order_id,
        CASE
            WHEN cc.cable_owner_code = '1' THEN 'Operator_Core'
            WHEN cc.cable_owner_code = '2' THEN 'Regional_Partner'
            WHEN cc.cable_owner_code = '3' THEN 'Subscriber_Drop'
            ELSE 'Other_Infrastructure'
        END
),
cables_with_parcels AS (
    -- [STAGE 9] Fetch Subscriber Cadastral Parcel Polygon via LATERAL Spatial Lookup
    SELECT
        os.*,
        cp.geom AS subscriber_parcel_geom
    FROM owner_segments os
    JOIN work_order_metadata wm
        ON wm.work_order_id = os.work_order_id
    LEFT JOIN LATERAL (
        SELECT ST_SetSRID(p.geom, 2180) AS geom
        FROM cadastre.cadastral_parcels p
        WHERE ST_Intersects(wm.start_geom, ST_SetSRID(p.geom, 2180))
        LIMIT 1
    ) cp ON true
)
-- [STAGE 10] Final Output Projection & Right-of-Way / Parcel Classification
SELECT
    nextval('analytics.subscriber_drop_routes_id_seq'::regclass) AS id,
    wm.work_order_id,
    wm.work_order_title,
    cwp.geom,
    cwp.owner_name       AS cable_owner,
    cwp.deployment_type,
    CASE
        WHEN cwp.subscriber_parcel_geom IS NULL THEN 'Road Right-of-Way'
        WHEN ST_Intersects(cwp.geom, cwp.subscriber_parcel_geom)
             AND ST_Length(ST_Difference(cwp.geom, cwp.subscriber_parcel_geom)) > 0.05
             THEN 'Mixed (Parcel + Right-of-Way)'
        WHEN ST_Intersects(cwp.geom, cwp.subscriber_parcel_geom)
             THEN 'Subscriber Parcel'
        ELSE 'Road Right-of-Way'
    END                  AS parcel_routing_class,
    n_start.designation  AS start_node_code,
    wm.target_backbone_node_id AS start_node_id,
    n_end.designation    AS end_node_code,
    wm.origin_customer_node_id AS end_node_id,
    wm.transit_node_names      AS intermediate_nodes,
    wm.transit_node_ids        AS intermediate_node_ids,
    cwp.cable_designations,
    cwp.cable_ids,
    feed_loc.id                AS feeding_location_id,
    concat_ws(' ', feed_loc.city, feed_loc.street, feed_loc.house_number) AS feeding_address
FROM cables_with_parcels cwp
JOIN work_order_metadata wm
    ON wm.work_order_id = cwp.work_order_id
LEFT JOIN telecom.network_nodes n_start
    ON n_start.id = wm.target_backbone_node_id
LEFT JOIN telecom.network_nodes n_end
    ON n_end.id = wm.origin_customer_node_id
LEFT JOIN telecom.v_structures vs
    ON vs.id = n_start.structure_id
LEFT JOIN inventory.network_locations feed_loc
    ON feed_loc.id = vs.location_id;


-- ---------------------------------------------------------------------------------------------
-- 2. Post-Batch Quality Assurance & Traversal Completeness Diagnostics
-- ---------------------------------------------------------------------------------------------
SELECT
    count(*)                                                          AS total_segments,
    count(DISTINCT work_order_id)                                     AS unique_work_orders,
    count(*) FILTER (WHERE start_node_id IS NOT NULL)                 AS resolved_backbone_endpoint,
    count(*) FILTER (WHERE start_node_id IS NULL)                     AS incomplete_topology_warning,
    round(
        count(*) FILTER (WHERE start_node_id IS NOT NULL) * 100.0
        / NULLIF(count(*), 0),
        2
    )                                                                 AS completion_rate_pct
FROM analytics.subscriber_drop_routes;
