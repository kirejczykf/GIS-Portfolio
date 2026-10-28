/**
 * =============================================================================================
 * MODULE 06: Custom JavaScript UI Extensions for LizMap WebGIS Client
 * =============================================================================================
 * Target Platform : LizMap Web Client (3Liz) — OpenLayers 2 / jQuery / LizMap Events API
 * Deployment      : Drop into `<lizmap-project-folder>/media/js/<project_name>/`
 *
 * Included Extensions:
 *   1. Duplicate-Address Save Interceptor (`MutationObserver`):
 *      Bridges PostgreSQL `ERRCODE 23505` trigger rejections (see Module 01) into a clear,
 *      debounced operator modal alert whenever LizMap's WFS-T edition form fails validation.
 *
 *   2. External Geoportal Coordinate Bridge (SIDUSIS & Google Maps):
 *      Injects toggleable crosshair map tools into LizMap's `#mapmenu` toolbar:
 *        - SIDUSIS (`internet.gov.pl`): Opens Poland's national broadband coverage portal
 *          centered directly on the clicked native planar coordinates (e.g. EPSG:2180).
 *        - Google Maps: Dynamically reprojects the clicked map coordinate from the project's
 *          native CRS to WGS84 (`EPSG:4326`) via `OpenLayers.Projection` and opens a pin.
 * =============================================================================================
 */

/* =============================================================================================
 * EXTENSION 1: Database Constraint / Duplicate-Address Form Error Interceptor
 * ============================================================================================= */
(function initDuplicateErrorInterceptor() {
    'use strict';

    const CONFIG = {
        debounceMs: 4000,
        errorMarkers: [
            'Napotkano błąd podczas zapisywania formularza',
            'Napotkano błąd',
            'DUPLICATE_ADDRESS'
        ],
        alertMessage:
            '⛔ BLOKADA ZAPISU: DUPLIKAT ADRESU! ⛔\n\n' +
            'Taki adres już istnieje w aktywnej bazie danych.\n' +
            'Sprawdź numer porządkowy budynku lub numer działki.'
    };

    let isAlertLocked = false;

    function triggerDuplicateAlert() {
        if (isAlertLocked) return;
        isAlertLocked = true;

        window.alert(CONFIG.alertMessage);

        window.setTimeout(function () {
            isAlertLocked = false;
        }, CONFIG.debounceMs);
    }

    function getEditionContainer() {
        return (
            document.getElementById('edition-form-container') ||
            document.getElementById('edition') ||
            document.body
        );
    }

    function hasFormSaveError() {
        const container = getEditionContainer();
        if (!container) return false;

        const text = container.innerText || container.textContent || '';
        return CONFIG.errorMarkers.some(function (marker) {
            return text.indexOf(marker) !== -1;
        });
    }

    const formObserver = new MutationObserver(function () {
        if (hasFormSaveError()) {
            triggerDuplicateAlert();
        }
    });

    function attachObserver() {
        const target = getEditionContainer();
        if (!target) return;

        formObserver.disconnect();
        formObserver.observe(target, {
            childList: true,
            subtree: true,
            characterData: true
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', attachObserver);
    } else {
        attachObserver();
    }

    // Re-bind observer whenever LizMap dynamically redraws the WFS-T edition form
    const lizmapInstance = window.lizMap || window.lizmap;
    if (lizmapInstance && lizmapInstance.events) {
        lizmapInstance.events.on({
            lizmapeditionformdisplayed: attachObserver,
            editionformdrawn: attachObserver
        });
    }
})();


/* =============================================================================================
 * EXTENSION 2: Interactive Toolbar Bridge to SIDUSIS (internet.gov.pl) & Google Maps
 * ============================================================================================= */
(function initExternalMapBridge() {
    'use strict';

    if (!window.lizMap || !lizMap.events) return;

    lizMap.events.on({
        uicreated: function () {
            // Embedded Base64 toolbar icons (no external static asset dependencies required)
            const sidusisIcon =
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABwAAAAcCAMAAABF0y+mAAAAz1BMVEVHcEz////////////////////////9/f7///////////////////////////////////////////////8AY9Lm5ucAXMQAM371+PsALnABbNhQUFAaGhrV4PG1v9EATKsAJGwAVbeYsdjl7Pbu8fUAQZhZj9koKCgAHGc4ODh2jbRdXV0AN5pRbJu6z+1zoeCkw+5lfaYpR3w7d8ra3eJBQUGjsMeInb2cprRiYmJLe8MkcMzV1tmXl5cgY7UuV5bMz9QICAh3eHgAFF8ADmHRIatgAAAAE3RSTlMAqNAZCb1+/vAxbOfdtkVJTJXOC5ugwAAAAcNJREFUKJFVk4tyqjAQQGNva6Ct7a0LBBDCWwEFAcVa3338/zfdDeAtnmGGyRyy2d0shHTIw9GzRKl0N3j8Q255fAJQD3yz4WsAuPvbU/IzqGnlxi4Sb9DCw/3VvQJNv11DwJiRAnAOUhdbhqCKDSNm56wssywAvlj4ILV7n/TKNeKMh9DhCwkD4YZQxsbPBn6hvq/jS0Yprb+NNgugDfjGR4cRIS9QukaGRj/OJw2imODk2HBP3vTKcC/46YfV8nkQxzrOFF7JeB2zCo84WMlFbRDn2Y530oeEcpeJqNz66uUUnjwvGBDYGgzrxp31OkQ6u9I8e0TgnbF3sZxbsyRJ6smxkTuUD7+Sttkms2MrNSG3rAl75ZLUYRNWw7CUs6jsSahrFYveKwomNLZZdMbsaVuHuk0muLI1ZY+lvOnnaJHjVX9aM0Ey24omKIpowgukUbRDOZ9/CL64aKVpKjm2j0j2wol8uGGqmKZoPF5ZGt1afamIjXJz2fTkeM4u75oTFHt0y/aycUzCveN5nraaIisFQ6LrxgRzokvH0wRKo8zi/4A1oxksV1c5LfTeaHZDHdh5UeQ2Hj3uD3X/dxj3fod/CCVHHrpDlf4AAAAASUVORK5CYII=';

            const googleIcon =
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABwAAAAcCAYAAAByDd+UAAAClElEQVR4AWJwL/ChKyZJ8eTK29FxDYBa6yEwliiKoujk27Zt27Zt27Zt27Zt27ZtxL7JGZzgNV5XY7CT9qpb9pvFCs7+N6/CjL/NnQp6r8wY+Vb3I0t2930m8wf/kGEjPKXzGD+pODFIUKGpAYKAJz82IrJDoFeTNsXetloY9LDDTlHBhuMDI4C5Z3lJ1oW/JMvyNyUMg8TcancUgue7XyJqFUyz/L2kXvOouCHQq0XFVN5VawnAr42HiQJiSqtgorX3Jebe5WlsBgOqlj1tDtzb9/Zn7Dhdxv1OgLDDFJvu9VnFUOzN5y9qQU4XUK2UAEQAsVqvd90yx9Jqwg4THoy+5QzilNbBgGolZgFEBF+1Gc+ltVjKFU8vh2Jo+16JsmfdHD1Yp+gzgv5Nigf+61xfMLUOxDQEI+/cKVH2LpOo+5Y81YJAUECXfEEIoA5jmIpYtIOTgpAWJBQ0LItf4Lgs4jc7y1VbQUxELMbRIYFICxIKnJFW/FelRjZPCIhYrGN9JPaJLu5aEBMR8tuXWDxOJJWfWzM102HJz3StTSjW8a4S+2SHkDoe1YKep5MMJIT+XU0st69m8cY51RKGcyimIcTSnm3XWwsiIOzj/RRy6lEuWXaj1O8lN0rnUz8b72THvMAAqNl8psGUgND9xxlk/cPiMvJudal+rbWUO9/8YbZzbdeiuCc63ccPYzL9dBZAXmI+PE7xABimCw/mv9RBEp5uxx8GZBIWxPDVAtvMEpj+nGUUqxcLbRhEx5/lSk2s7e2mKmgW5fnTMMiwo+hAhh3IKfc0Fa82LaOC6mrFZ5x6E4W9zhyIuEc6FUQ4FFQQr7nsNhEVvNzpN0GeK10K4pzJ6fDY5SC3J3L5nbd6NrKnYImusD97UAbLAAAAAElFTkSuQmCC';

            const googleBtnHtml =
                '<li class="nav-item" style="float: right;">' +
                '<a href="#" id="btn-ext-google" title="Google Maps — click on the map to open Street View / Pin" ' +
                'class="nav-link" style="padding: 1px 5px; text-align: center; display: block;">' +
                '<img src="' + googleIcon + '" style="height: 22px; width: 22px; vertical-align: middle;" alt="Google Maps" />' +
                '</a></li>';

            const sidusisBtnHtml =
                '<li class="nav-item" style="float: right;">' +
                '<a href="#" id="btn-ext-sidusis" title="SIDUSIS (internet.gov.pl) — click on the map to inspect broadband coverage" ' +
                'class="nav-link" style="padding: 1px 5px; text-align: center; display: block;">' +
                '<img src="' + sidusisIcon + '" style="height: 20px; width: 30px; vertical-align: middle;" alt="SIDUSIS" />' +
                '</a></li>';

            $('#mapmenu').append(googleBtnHtml);
            $('#mapmenu').append(sidusisBtnHtml);

            let activeTool = null; // 'sidusis' | 'google' | null

            function resetTools() {
                activeTool = null;
                $('#btn-ext-sidusis, #btn-ext-google').css('background-color', '');
                $('#map').css('cursor', 'default');
            }

            function toggleTool(toolName, buttonSelector) {
                if (activeTool === toolName) {
                    resetTools();
                } else {
                    resetTools();
                    activeTool = toolName;
                    $(buttonSelector).css('background-color', '#ffff99');
                    $('#map').css('cursor', 'crosshair');
                }
            }

            $('#btn-ext-sidusis').on('click', function (evt) {
                evt.preventDefault();
                toggleTool('sidusis', '#btn-ext-sidusis');
            });

            $('#btn-ext-google').on('click', function (evt) {
                evt.preventDefault();
                toggleTool('google', '#btn-ext-google');
            });

            // Handle single click on the OpenLayers 2 map canvas
            lizMap.map.events.register('click', lizMap.map, function (evt) {
                if (!activeTool) return;

                const mapCoords = lizMap.map.getLonLatFromPixel(evt.xy);

                if (activeTool === 'sidusis') {
                    // SIDUSIS expects planar EPSG:2180 coordinates directly in the URL query
                    const x = mapCoords.lon;
                    const y = mapCoords.lat;
                    const sidusisUrl = 'https://internet.gov.pl/map/?center=' + encodeURIComponent(x + ';' + y) + '&zoom=19';
                    window.open(sidusisUrl, '_blank', 'noopener');
                } else if (activeTool === 'google') {
                    // Reproject from project CRS (e.g. EPSG:2180 / EPSG:3857) to WGS84 (EPSG:4326)
                    try {
                        const sourceProj = lizMap.map.getProjectionObject();
                        const targetProj = new OpenLayers.Projection('EPSG:4326');
                        const wgs84Coords = mapCoords.clone().transform(sourceProj, targetProj);

                        const googleUrl =
                            'https://www.google.com/maps/search/?api=1&query=' +
                            encodeURIComponent(wgs84Coords.lat + ',' + wgs84Coords.lon);
                        window.open(googleUrl, '_blank', 'noopener');
                    } catch (err) {
                        console.error('Coordinate transformation failed:', err);
                        window.alert('Failed to reproject coordinates to WGS84 (EPSG:4326).');
                    }
                }

                resetTools();
            });
        }
    });
})();
