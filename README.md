# GIS Portfolio - Telecom & Spatial SQL
Collection of advanced Spatial SQL (PostGIS) scripts, data engineering workflows, and QGIS/Lizmap configurations tailored for Telecom Network Inventory management.

## Project 1: Automated Address Integration (ETL)

**File:** `telecom_address_sync.sql`

### Problem
The telecom network planning team needed to update the fiber-optic coverage map with new address points from the National Register (PRG). The challenge was to import hundreds of points weekly without creating duplicates for buildings that already existed in the internal inventory.

### Solution
I developed a pure **PostgreSQL/PostGIS** automation script that:
1.  **Ingests and Cleans Data:** Filters raw external data (PRG) and standardizes administrative codes.
2.  **Spatial Joins:** Integrates address points with Cadastral Parcels (ULDK) to assign property IDs automatically.
3.  **Topology Checks:** Uses `ST_Contains` logic to ensure new points are not placed inside existing building footprints or near existing network nodes.
4.  **Performance:** Replaced manual verification (hours of work) with a query that runs in seconds.

### Tech Stack
*   **Database:** PostgreSQL 14 + PostGIS 3.x
*   **Logic:** CTEs (Common Table Expressions), Spatial Joins, Window Functions
*   **Tools:** QGIS (for visualization), Lizmap (for publishing results)

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
