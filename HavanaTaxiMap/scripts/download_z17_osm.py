"""Descarga los tiles de zoom 17 de La Habana desde OpenStreetMap.

Sustituye los placeholder de Carto (que quedo bloqueado). Borra la carpeta
tiles/17 y baja el nivel completo con las mismas fronteras del original.
"""
import os
import math
import time
import ssl
import sys
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

HAVANA_BOUNDS = {
    'min_lat': 22.90,
    'max_lat': 23.30,
    'min_lon': -82.60,
    'max_lon': -82.00,
}

ZOOM = 17
TILE_SOURCE = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
TILES_DIR = os.path.join(os.path.dirname(__file__), '..', 'tiles')
MAX_WORKERS = 12
MAX_RETRIES = 4
REQUEST_TIMEOUT = 40

ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

UA = 'TaxiRapid-HavanaMap/1.0 (copia local de tiles; contacto: dev@taxirapid.local)'


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
                'User-Agent': UA,
                'Referer': 'https://taxirapid.local/',
            })
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT, context=ssl_context) as r:
                data = r.read()
                if len(data) < 100 or not data.startswith(b'\x89PNG'):
                    raise Exception("Tile invalido")
                with open(path, 'wb') as f:
                    f.write(data)
                return 'ok'
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code == 403:
                time.sleep(MAX_RETRIES + attempt)
            else:
                time.sleep(0.5 * (attempt + 1))
        except Exception:
            if attempt < MAX_RETRIES - 1:
                time.sleep(0.5 * (attempt + 1))
    return 'error'


def main():
    z = ZOOM
    x_min = lon_to_x(HAVANA_BOUNDS['min_lon'], z)
    x_max = lon_to_x(HAVANA_BOUNDS['max_lon'], z)
    y_min = lat_to_y(HAVANA_BOUNDS['max_lat'], z)
    y_max = lat_to_y(HAVANA_BOUNDS['min_lat'], z)

    z_dir = os.path.join(TILES_DIR, str(z))
    if os.path.isdir(z_dir):
        import shutil
        shutil.rmtree(z_dir)
        print('carpeta z17 anterior borrada (placeholder de Carto)')

    tiles = [(z, x, y) for x in range(x_min, x_max + 1) for y in range(y_min, y_max + 1)]
    total = len(tiles)
    print(f"Descargando {total} tiles z{z} desde OpenStreetMap ({MAX_WORKERS} hilos)")

    ok = errors = 0
    start = time.time()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futs = {ex.submit(download_tile, z, x, y): (z, x, y) for z, x, y in tiles}
        done = 0
        for fut in as_completed(futs):
            if fut.result() == 'ok':
                ok += 1
            else:
                errors += 1
            done += 1
            if done % 250 == 0 or done == total:
                el = time.time() - start
                sp = done / el if el else 0
                eta = (total - done) / sp if sp else 0
                print(f"\r  [{done / total * 100:5.1f}%] {done}/{total} OK {ok} ERR {errors} {sp:.1f} t/s ETA {eta:.0f}s", end='', flush=True)

    el = time.time() - start
    print(f"\n\nz17 completado en {el / 60:.1f} min | OK {ok} | Errores {errors}")
    print(f"Tiles en disco z17: {sum(len(f) for _, _, f in os.walk(os.path.join(TILES_DIR, '17')))}")


if __name__ == '__main__':
    main()