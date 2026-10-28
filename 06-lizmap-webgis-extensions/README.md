# 06 — Custom JavaScript UI Extensions for LizMap WebGIS

## Business Problem
Over **100 non-technical and engineering users** (customer service, network planners, field dispatchers) rely on **LizMap Web Client** (publishing 20+ QGIS projects across 15+ repositories) as their daily operational map interface. Two recurring UX friction points slowed daily work:
1. **Subtle WFS-T Form Error Banner:** When PostgreSQL's `BEFORE INSERT OR UPDATE` trigger ([Module 01](../01-address-validation-trigger/)) rejected a duplicate address (`SQLSTATE 23505`), LizMap rendered a small inline notice inside `#edition-form-container` that editors frequently overlooked, believing their point had been saved.
2. **Manual Coordinate Copy-Pasting:** Network planners constantly cross-checked candidate FTTH locations against Poland's government broadband portal (**SIDUSIS — `internet.gov.pl`**) and **Google Maps / Street View**, manually copying coordinates and converting between `EPSG:2180` (`PUWG 1992`) and `EPSG:4326` (`WGS84`).

## Engineering Solution
Developed a lightweight, dependency-free JavaScript extension ([`lizmap_custom_tools.js`](./lizmap_custom_tools.js)) deployed via LizMap's project `media/js/` mechanism:

1. **Duplicate-Address Save Interceptor (`MutationObserver`):**
   - Hooks into LizMap's `lizmapeditionformdisplayed` and `editionformdrawn` lifecycle events.
   - Monitors DOM mutations inside `#edition-form-container` and triggers a prominent, 4-second debounced modal alert (`BLOKADA ZAPISU: DUPLIKAT ADRESU!`) the instant a database constraint rejection appears.
2. **One-Click Coordinate Bridge (`SIDUSIS` & `Google Maps`):**
   - Injects two self-contained Base64 icon buttons into `#mapmenu` on `uicreated` with visual active-tool state (`crosshair` cursor + highlight).
   - **SIDUSIS Integration:** Extracts native `EPSG:2180` click coordinates (`lizMap.map.getLonLatFromPixel`) and deep-links straight to zoom level 19 on `https://internet.gov.pl/map/`.
   - **Google Maps Integration:** Dynamically reprojects map coordinates client-side via `OpenLayers.Projection('EPSG:4326')` (`mapCoords.clone().transform(...)`) and opens the exact WGS84 location in a new tab (`noopener`).

## File
- [`lizmap_custom_tools.js`](./lizmap_custom_tools.js) — Self-contained LizMap JavaScript user scripts (ES6+, IIFE-scoped).
