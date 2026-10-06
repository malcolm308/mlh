(function () {
    const HAVANA_CENTER = [23.1352, -82.3589];
    const TILE_CDN = 'https://a.basemaps.cartocdn.com/rastertiles/voyager';
    const TILE_LOCAL = '/tiles';
    const FARE_PER_KM = 1.50;
    const FARE_BASE = 2.00;

    let map;
    let pickupMarker = null;
    let destMarker = null;
    let routeLine = null;
    let pickupCoords = null;
    let destCoords = null;
    let searchTimeout = null;
    let tileCacheDB = null;
    let tileQueue = [];
    let isProcessingQueue = false;

    function initCacheDB() {
        return new Promise((resolve, reject) => {
            const request = indexedDB.open('HavanaTileCache', 1);

            request.onupgradeneeded = (e) => {
                const db = e.target.result;
                if (!db.objectStoreNames.contains('tiles')) {
                    db.createObjectStore('tiles', { keyPath: 'key' });
                }
            };

            request.onsuccess = (e) => {
                tileCacheDB = e.target.result;
                resolve();
            };

            request.onerror = (e) => {
                console.warn('IndexedDB no disponible, usando caché en memoria');
                resolve();
            };
        });
    }

    function getCachedTile(key) {
        return new Promise((resolve) => {
            if (!tileCacheDB) { resolve(null); return; }

            try {
                const tx = tileCacheDB.transaction('tiles', 'readonly');
                const store = tx.objectStore('tiles');
                const request = store.get(key);

                request.onsuccess = () => resolve(request.result || null);
                request.onerror = () => resolve(null);
            } catch (e) {
                resolve(null);
            }
        });
    }

    function cacheTile(key, blob) {
        if (!tileCacheDB) return;

        tileQueue.push({ key, blob });

        if (!isProcessingQueue) {
            processTileQueue();
        }
    }

    function processTileQueue() {
        if (tileQueue.length === 0 || !tileCacheDB) {
            isProcessingQueue = false;
            return;
        }

        isProcessingQueue = true;
        const batch = tileQueue.splice(0, 10);

        try {
            const tx = tileCacheDB.transaction('tiles', 'readwrite');
            const store = tx.objectStore('tiles');

            batch.forEach(({ key, blob }) => {
                store.put({ key, blob, timestamp: Date.now() });
            });

            tx.oncomplete = () => processTileQueue();
            tx.onerror = () => { isProcessingQueue = false; };
        } catch (e) {
            isProcessingQueue = false;
        }
    }

    L.TileLayer.CachedTileLayer = L.TileLayer.extend({
        createTile: function(coords, done) {
            const tile = document.createElement('img');
            const key = `${coords.z}/${coords.x}/${coords.y}`;

            tile.onload = () => done(null, tile);

            getCachedTile(key).then(cached => {
                if (cached) {
                    const url = URL.createObjectURL(cached.blob);
                    tile.src = url;
                    tile.onload = () => { URL.revokeObjectURL(url); done(null, tile); };
                    return;
                }

                const cdnUrl = `${TILE_CDN}/${coords.z}/${coords.x}/${coords.y}.png`;

                fetch(cdnUrl)
                    .then(res => res.blob())
                    .then(blob => {
                        cacheTile(key, blob);
                        const url = URL.createObjectURL(blob);
                        tile.src = url;
                        tile.onload = () => { URL.revokeObjectURL(url); done(null, tile); };
                    })
                    .catch(() => {
                        tile.src = `${TILE_CDN}/${coords.z}/${coords.x}/${coords.y}.png`;
                    });
            });

            return tile;
        }
    });

    function initMap() {
        map = L.map('map', {
            center: HAVANA_CENTER,
            zoom: 13,
            zoomControl: true,
            preferCanvas: true,
            wheelPxPerZoomLevel: 100,
            zoomAnimationThreshold: 2
        });

        new L.TileLayer.CachedTileLayer('', {
            attribution: '© <a href="https://www.openstreetmap.org/copyright" target="_blank">Colaboradores de OpenStreetMap</a>',
            maxZoom: 20,
            tileSize: 256,
            updateWhenZooming: false,
            updateWhenIdle: true,
            keepBuffer: 4
        }).addTo(map);

        map.on('click', onMapClick);
    }

    function onMapClick(e) {
        const { lat, lng } = e.latlng;
        if (!pickupCoords) {
            setPickup(lat, lng);
        } else if (!destCoords) {
            setDest(lat, lng);
        }
    }

    function createCustomMarker(iconUrl, color) {
        return L.divIcon({
            className: 'custom-marker',
            html: `<div style="
                background: ${color};
                width: 30px;
                height: 30px;
                border-radius: 50% 50% 50% 0;
                transform: rotate(-45deg);
                display: flex;
                align-items: center;
                justify-content: center;
                box-shadow: 0 2px 6px rgba(0,0,0,0.3);
                border: 3px solid #fff;
            "><span style="transform: rotate(45deg); font-size: 14px;">${iconUrl}</span></div>`,
            iconSize: [30, 30],
            iconAnchor: [15, 30]
        });
    }

    function setPickup(lat, lng) {
        pickupCoords = [lat, lng];
        if (pickupMarker) map.removeLayer(pickupMarker);
        pickupMarker = L.marker([lat, lng], {
            icon: createCustomMarker('🟢', '#4caf50')
        }).addTo(map).bindPopup('Origen').openPopup();

        reverseGeocode(lat, lng).then(name => {
            document.getElementById('pickup-search').value = name;
        });

        checkAndCalculateRoute();
    }

    function setDest(lat, lng) {
        destCoords = [lat, lng];
        if (destMarker) map.removeLayer(destMarker);
        destMarker = L.marker([lat, lng], {
            icon: createCustomMarker('🔴', '#ef5350')
        }).addTo(map).bindPopup('Destino').openPopup();

        reverseGeocode(lat, lng).then(name => {
            document.getElementById('dest-search').value = name;
        });

        checkAndCalculateRoute();
    }

    function checkAndCalculateRoute() {
        if (pickupCoords && destCoords) {
            calculateRoute();
            document.getElementById('route-info').classList.remove('hidden');
            document.getElementById('instructions').classList.add('hidden');
            document.getElementById('clear-btn').classList.remove('hidden');
        }
    }

    function calculateRoute() {
        if (!pickupCoords || !destCoords) return;

        const url = `https://router.project-osrm.org/route/v1/driving/${pickupCoords[1]},${pickupCoords[0]};${destCoords[1]},${destCoords[0]}?overview=full&geometries=geojson`;

        fetch(url)
            .then(res => res.json())
            .then(data => {
                if (!data.routes || data.routes.length === 0) return;

                const route = data.routes[0];
                const distanceKm = route.distance / 1000;
                const durationMin = Math.ceil(route.duration / 60);
                const fare = (FARE_BASE + distanceKm * FARE_PER_KM).toFixed(2);

                if (routeLine) map.removeLayer(routeLine);

                routeLine = L.geoJSON(route.geometry, {
                    style: { color: '#4361ee', weight: 5, opacity: 0.8 }
                }).addTo(map);

                const group = L.featureGroup([pickupMarker, destMarker, routeLine]);
                map.fitBounds(group.getBounds().pad(0.15));

                document.getElementById('distance').textContent = distanceKm.toFixed(1) + ' km';
                document.getElementById('duration').textContent = durationMin + ' min';
                document.getElementById('fare').textContent = '$' + fare;
            })
            .catch(err => console.error('Error calculando ruta:', err));
    }

    function searchAddress(query, target) {
        if (query.length < 3) return;

        const url = `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(query)}&format=json&limit=5&countrycodes=cu&viewbox=-82.55,23.3,-82.15,22.9&bounded=1&accept-language=es`;

        fetch(url, { headers: { 'User-Agent': 'TaxiHabana/1.0' } })
            .then(res => res.json())
            .then(results => {
                const container = document.getElementById(target === 'pickup' ? 'pickup-results' : 'dest-results');
                container.innerHTML = '';

                if (results.length === 0) {
                    container.innerHTML = '<div class="search-result-item">No se encontraron resultados</div>';
                    container.classList.add('active');
                    return;
                }

                results.forEach(r => {
                    const div = document.createElement('div');
                    div.className = 'search-result-item';
                    div.textContent = r.display_name;
                    div.addEventListener('click', () => {
                        const lat = parseFloat(r.lat);
                        const lon = parseFloat(r.lon);
                        if (target === 'pickup') {
                            setPickup(lat, lon);
                            document.getElementById('pickup-search').value = r.display_name;
                            container.classList.remove('active');
                        } else {
                            setDest(lat, lon);
                            document.getElementById('dest-search').value = r.display_name;
                            container.classList.remove('active');
                        }
                    });
                    container.appendChild(div);
                });

                container.classList.add('active');
            })
            .catch(err => console.error('Error buscando:', err));
    }

    function reverseGeocode(lat, lng) {
        const url = `https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lng}&format=json&accept-language=es`;
        return fetch(url, { headers: { 'User-Agent': 'TaxiHabana/1.0' } })
            .then(res => res.json())
            .then(data => data.display_name || 'Ubicación seleccionada')
            .catch(() => 'Ubicación seleccionada');
    }

    function clearAll() {
        if (pickupMarker) { map.removeLayer(pickupMarker); pickupMarker = null; }
        if (destMarker) { map.removeLayer(destMarker); destMarker = null; }
        if (routeLine) { map.removeLayer(routeLine); routeLine = null; }
        pickupCoords = null;
        destCoords = null;

        document.getElementById('pickup-search').value = '';
        document.getElementById('dest-search').value = '';
        document.getElementById('route-info').classList.add('hidden');
        document.getElementById('instructions').classList.remove('hidden');
        document.getElementById('clear-btn').classList.add('hidden');

        map.setView(HAVANA_CENTER, 13);
    }

    function getMyLocation() {
        if (!navigator.geolocation) {
            alert('Geolocalización no disponible');
            return;
        }

        navigator.geolocation.getCurrentPosition(
            (pos) => {
                setPickup(pos.coords.latitude, pos.coords.longitude);
                map.setView([pos.coords.latitude, pos.coords.longitude], 15);
            },
            () => alert('No se pudo obtener tu ubicación. Selecciona el origen en el mapa.')
        );
    }

    function setupSearch() {
        const pickupInput = document.getElementById('pickup-search');
        const destInput = document.getElementById('dest-search');

        pickupInput.addEventListener('input', (e) => {
            clearTimeout(searchTimeout);
            const val = e.target.value.trim();
            if (val.length >= 3) {
                searchTimeout = setTimeout(() => searchAddress(val, 'pickup'), 600);
            } else {
                document.getElementById('pickup-results').classList.remove('active');
            }
        });

        destInput.addEventListener('input', (e) => {
            clearTimeout(searchTimeout);
            const val = e.target.value.trim();
            if (val.length >= 3) {
                searchTimeout = setTimeout(() => searchAddress(val, 'dest'), 600);
            } else {
                document.getElementById('dest-results').classList.remove('active');
            }
        });

        document.addEventListener('click', (e) => {
            if (!e.target.closest('.search-box')) {
                document.getElementById('pickup-results').classList.remove('active');
                document.getElementById('dest-results').classList.remove('active');
            }
        });
    }

    function setupButtons() {
        document.getElementById('clear-btn').addEventListener('click', clearAll);
        document.getElementById('my-location-btn').addEventListener('click', getMyLocation);
    }

    function init() {
        initCacheDB().then(() => {
            initMap();
        });
        setupSearch();
        setupButtons();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
