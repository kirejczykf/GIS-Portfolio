# 04 — Spatial ETL: PRG Address Sync & Cadastral Parcel Lineage (`ST_Buffer -1m`)

## Business Problem
Telecom operators rely on external public spatial registers (**PRG** national address points, **EGiB/ULDK** cadastral parcels, and **BDOT10k** building footprints) that evolve continuously:
1. Weekly **PRG** releases introduce thousands of new addresses, many of which fall inside buildings already mapped under slightly shifted coordinates in the operator's inventory.
2. Periodic **cadastral updates (EGiB/ULDK)** split and merge land parcels, invalidating static `parcel_number` references on network assets and right-of-way lease agreements if historical `old_parcel_id → new_parcel_id` lineage is lost.

## Engineering Solution
This module contains two production Spatial ETL workflows running purely inside PostgreSQL/PostGIS (`EPSG:2180`):

### 1. [`01_prg_address_spatial_sync.sql`](./01_prg_address_spatial_sync.sql) — Dual Anti-Join PRG Ingestion
- Deduplicates raw PRG records and enriches each point with its containing cadastral parcel (`ST_Contains`).
- Prevents logical duplicates via **two spatial anti-joins**:
  1. `ST_DWithin(..., 1.0)` against existing `inventory.network_locations` points.
  2. Building-level anti-join via **BDOT10k** (`topography.building_footprints`): suppresses PRG points falling inside any building polygon that already contains an active network location.

### 2. [`02_cadastral_parcel_lineage_etl.sql`](./02_cadastral_parcel_lineage_etl.sql) — Subdivision Lineage & In-Place Refresh
- Parses hierarchical national parcel IDs (`WWPPGG_R.OOOO.NR`) into `terc`, `district_code`, and `parcel_number`, and isolates retired vs. newly added parcels via anti-joins with dedicated **GiST** indexes.
- **Negative Buffer Topology Pattern (`ST_Buffer(ret.geom, -1.0)`):** Plain `ST_Intersects(old.geom, new.geom)` produces thousands of false-positive matches because adjacent parcels share boundary lines. Applying a `-1.0 m` inward buffer shrinks the retired polygon away from shared borders so `ST_Intersects` links **only true interior successor parcels** into `cadastre.retired_parcels_lineage`.
- **Permission-Safe Refresh:** Refreshes `cadastre.cadastral_parcels` inside an atomic transaction (`BEGIN ... COMMIT`) without dropping the table, preserving 100+ user RBAC grants and dependent materialized views, then cascades updated parcel numbers to `inventory.network_locations` via `ST_Within`.
