# GIS Portfolio - Telecom & Spatial SQL
Collection of advanced Spatial SQL (PostGIS) scripts, data engineering workflows, and QGIS/Lizmap configurations tailored for Telecom Network Inventory management.

## Project 1: Automated Address Integration (Spatial ETL)

**Objective**
The telecom network planning team required frequent updates to the fiber-optic coverage map using new address points from the National Register (PRG). The challenge was to import thousands of points weekly without creating duplicates for buildings already existing in the internal inventory.

**Technical Solution**
I developed a pure PostgreSQL/PostGIS automation script that replaces manual verification with a spatial query running in seconds.

Key features:
*   **Data Ingestion & Cleaning:** Filters raw external data (PRG) and standardizes administrative codes using CTEs.
*   **Spatial Joins:** Integrates address points with Cadastral Parcels (ULDK) to automatically assign property IDs using spatial containment logic (`ST_Contains`).
*   **Topology Checks:** Uses spatial anti-joins to ensure new points are not placed inside existing building footprints or near existing network nodes.
*   **Coordinate System Management:** Enforces EPSG:2180 standardization for consistent geometry operations.

**Tech Stack**
*   PostgreSQL 14
*   PostGIS 3.x (Spatial SQL)
*   QGIS (Visualization)

[View SQL Script](./telecom_address_sync.sql)

## Project 2: Automated Data Enrichment for Network Infrastructure

### Objective
To automate the data quality assurance process for a fiber optic network inventory containing thousands of records. The goal was to eliminate NULL values and simulate realistic network load for regulatory compliance reporting (UKE).

### Technical Solution
I developed a robust PostgreSQL script that performs bulk updates based on conditional logic.
*   **Common Table Expressions (CTEs):** Used to isolate the "snapshot" of the data and perform calculations without locking the main table for too long.
*   **Probabilistic Modeling:** Implemented a randomized growth algorithm to simulate natural network usage patterns for new infrastructure.
*   **Data Integrity Constraints:** Used `LEAST/GREATEST` and `COALESCE` functions to ensure the calculated values never exceed physical cable capacity or drop below logical zero.
*   **Atomic Updates:** Utilized the `UPDATE ... FROM` syntax to apply changes efficiently in a single transaction.

### Code
[View SQL Script](./network_capacity_backfill.sql)
