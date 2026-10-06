import os
import math
import urllib.request
import ssl
import time
import sys
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

HAVANA_BOUNDS = {
    'min_lat': 22.90,
    'max_lat': 23.30,
    'min_lon': -82.60,
    'max_lon': -82.00
}

ZOOM_LEVELS = [10, 11, 12, 13, 14, 15, 16, 17, 18]
TILE_SOURCE = 'https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png'
TILES_DIR = os.path.join(os.path.dirname(__file__), '..', 'tiles')
MAX_WORKERS = 16
MAX_RETRIES = 3
REQUEST_TIMEOUT = 30

ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

def lon_to_x(lon, zoom):
    return int((lon + 180.0) / 360.0 * (2 ** zoom))

def lat_to_y(lat, zoom):
    lat_rad = math.radians(lat)
    n = 2.0 ** zoom
    return int((1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * n)

def download_tile(z, x, y):
    path = os.path.join(TILES_DIR, str(z), str(x), f"{y}.png")

    if os.path.exists(path) and os.path.getsize(path) > 500:
        return 'skip'

    os.makedirs(os.path.dirname(path), exist_ok=True)

    for attempt in range(MAX_RETRIES):
        try:
            url = TILE_SOURCE.format(z=z, x=x, y=y)
            req = urllib.request.Request(url, headers={
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            })
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT, context=ssl_context) as response:
                data = response.read()
                if len(data) < 100:
                    raise Exception("Tile vacio")
                with open(path, 'wb') as f:
                    f.write(data)
                return 'ok'
        except:
            if attempt < MAX_RETRIES - 1:
                time.sleep(0.5)

    return 'error'

def main():
    tiles_list = []

    for zoom in ZOOM_LEVELS:
        x_min = lon_to_x(HAVANA_BOUNDS['min_lon'], zoom)
        x_max = lon_to_x(HAVANA_BOUNDS['max_lon'], zoom)
        y_min = lat_to_y(HAVANA_BOUNDS['max_lat'], zoom)
        y_max = lat_to_y(HAVANA_BOUNDS['min_lat'], zoom)

        for x in range(x_min, x_max + 1):
            for y in range(y_min, y_max + 1):
                tiles_list.append((zoom, x, y))

    total = len(tiles_list)
    print(f"Descargando {total} tiles (zoom {ZOOM_LEVELS[0]}-{ZOOM_LEVELS[-1]}) con {MAX_WORKERS} hilos\n")

    downloaded = 0
    skipped = 0
    errors = 0
    start = time.time()

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(download_tile, z, x, y): (z, x, y) for z, x, y in tiles_list}

        for future in as_completed(futures):
            result = future.result()
            if result == 'ok':
                downloaded += 1
            elif result == 'skip':
                skipped += 1
            else:
                errors += 1

            done = downloaded + skipped + errors
            if done % 100 == 0 or done == total:
                pct = done / total * 100
                elapsed = time.time() - start
                speed = done / elapsed if elapsed > 0 else 0
                eta = (total - done) / speed if speed > 0 else 0
                print(f"\r  [{pct:5.1f}%] {done}/{total} | OK: {downloaded} | Cache: {skipped} | Errores: {errors} | {speed:.1f} t/s | ETA: {eta:.0f}s", end='', flush=True)

    elapsed = time.time() - start
    print(f"\n\nCompletado en {elapsed:.0f}s ({elapsed/60:.1f} min)!")
    print(f"Descargados: {downloaded} | Cache: {skipped} | Errores: {errors}")

    for z in sorted(range(10, 17)):
        z_dir = os.path.join(TILES_DIR, str(z))
        if os.path.exists(z_dir):
            count = sum(len(files) for _, _, files in os.walk(z_dir))
            print(f"  Zoom {z}: {count} tiles")

if __name__ == '__main__':
    main()
