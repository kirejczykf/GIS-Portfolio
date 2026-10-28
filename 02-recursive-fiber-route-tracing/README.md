# 02 — Recursive Fiber-Optic Drop-Cable Route Tracing (`WITH RECURSIVE`)

## Business Problem
In FTTH (Fiber-to-the-Home) network inventory systems, a single subscriber drop connection rarely consists of one straight line. Physically, the optical path runs from the customer's **ONT / wall socket** across multiple micro-cables, poles, manholes, and pass-through joints (`cable_count <= 2`) before reaching a **backbone distribution splice closure** (`cable_count > 2`), often crossing multiple infrastructure owners and cadastral boundaries.

Asset management, IT service desks, and lease-settlement teams needed an automated way to reconstruct full subscriber drop routes, segment them by **infrastructure owner**, trim indoor schematic cable tails to **actual building walls**, and classify whether each segment runs strictly within the **subscriber's parcel** or crosses **public road right-of-way**.

## Engineering Solution
Implemented a pure PostgreSQL/PostGIS **10-stage CTE pipeline** (`recursive_drop_route_tracing.sql`) without external graph libraries:

1. **Topological Node-Degree Classification (`node_degrees`):** Unions `from_node_id` and `to_node_id` across `telecom.optical_cables` to identify pass-through joints (`cable_count <= 2`) vs. distribution splice closures (`cable_count > 2`).
2. **Cycle-Safe Undirected Graph Traversal (`WITH RECURSIVE route_traversal`):** Walks upstream from the customer termination node across bidirectional cable edges (`to_node_id = n.id OR from_node_id = n.id`) while maintaining `visited_cables` and `visited_nodes` arrays (`NOT (id = ANY(visited_...))`) to guarantee termination even in cyclic ring topologies.
3. **Shortest Valid Path Extraction (`DISTINCT ON`):** Selects the minimum-hop path (`ORDER BY work_order_id, hop_depth ASC`) reaching a distribution closure.
4. **Topological Footprint Clipping (`ST_Difference` + `ST_DWithin`):** Uses a `100 m` spatial bounding-box pre-filter (`ST_DWithin`) against **BDOT10k** building footprints (`topography.building_footprints`) before subtracting indoor geometry tails via `ST_Difference`.
5. **Owner-Level Geometry Consolidation:** Merges contiguous clipped segments per owner (`Operator_Core`, `Regional_Partner`, `Subscriber_Drop`) using `ST_Multi(ST_CollectionExtract(ST_Collect(...), 2))` and classifies deployment type (`Aerial`, `Underground`, `Mixed`).
6. **`LEFT JOIN LATERAL` Parcel Classification:** Intersects the subscriber's cadastral parcel (`cadastre.cadastral_parcels`) and measures residual exterior length (`ST_Length(ST_Difference(...)) > 0.05` m tolerance) to classify routes into `'Subscriber Parcel'`, `'Road Right-of-Way'`, or `'Mixed (Parcel + Right-of-Way)'`.
7. **Incremental Batching & QA Audit:** Anti-joins `analytics.subscriber_drop_routes` (`LIMIT 1000`) for safe iterative backfills and validates route completeness with `COUNT(*) FILTER (WHERE ...)`.

## File
- [`recursive_drop_route_tracing.sql`](./recursive_drop_route_tracing.sql) — Complete 10-stage recursive SQL + PostGIS pipeline and QA diagnostics.
