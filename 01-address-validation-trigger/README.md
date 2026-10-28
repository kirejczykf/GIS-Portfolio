# 01 — Real-Time Spatial Address Validation & TERYT Auto-Enrichment Trigger

## Business Problem
In a multi-user telecom GIS environment (**100+ internal staff** editing address layers via **QGIS** and **LizMap WebGIS**), manual address creation routinely introduced three data-quality defects:
1. **Missing or mismatched national registry codes (`TERC`, `SIMC`, `ULIC`)**, breaking downstream regulatory reporting (PIT/UKE, SIDUSIS) and CRM/ERP synchronization.
2. **Duplicate building locations** caused by trailing whitespace, inconsistent street formatting, or simultaneous edits across planning teams.
3. **Ambiguous unnumbered infrastructure points** (e.g., telecom cabinets, construction plots, or multiple buildings under construction on a single cadastral parcel where `house_number IS NULL`).

## Engineering Solution
Instead of relying on client-side QGIS form expressions that can be bypassed in WebGIS or SQL imports, all validation and spatial enrichment rules are centralized in a **`BEFORE INSERT OR UPDATE` PL/pgSQL trigger** (`inventory.fn_validate_and_enrich_location()`):

- **Spatial Point-in-Polygon `TERC` Resolution:** Extracts the 7-digit municipality & type code directly from the inserted point's geometry (`EPSG:2180`) via GiST-indexed `ST_Intersects` against cadastral district polygons (`cadastre.cadastral_districts`).
- **Official Dictionary Matching (`SIMC` & `ULIC`):** Automatically resolves locality and street codes from reference dictionaries and assigns the Polish standard `'99999'` street code when a rural locality has no registered streets (`NOT EXISTS`).
- **Dynamic Parcel Sub-Addressing (`A`, `B`, `C`):** When `house_number IS NULL`, the trigger validates parcel metadata and checks existing points on the same `(parcel_number, simc, left(terc, 7))`:
  - **1st point on parcel:** Saved cleanly without suffix.
  - **2nd point on parcel:** Retroactively updates the first point's `aux_subaddress` to `'A'` and assigns `'B'` to the incoming row.
  - **Subsequent points:** Increments sequentially (`chr(ascii(v_max_letter) + 1)`).
- **NULL-Safe Active Duplicate Blocking:** Uses `IS NOT DISTINCT FROM` across normalized address attributes while excluding archived/merged historical records (`merged_into_id IS NULL`), raising standard `SQLSTATE '23505'` (`unique_violation`) with the conflicting `location_id` and parcel number.
- **Scoped Trigger Firing:** Declared as `BEFORE INSERT OR UPDATE OF city, street, house_number, parcel_number, geom, terc, simc, ulic` so routine non-address attribute updates never incur spatial lookup overhead.

## End-to-End Integration with WebGIS
When an operator triggers `ERRCODE '23505'` inside LizMap Web Client, the companion frontend script in **[06-lizmap-webgis-extensions](../06-lizmap-webgis-extensions/)** intercepts the form error via `MutationObserver` and displays a clear modal alert.

## File
- [`address_validation_trigger.sql`](./address_validation_trigger.sql) — Reference constraints, indexes, PL/pgSQL trigger functions, and trigger bindings.
