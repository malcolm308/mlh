"""Descarga los tiles de zoom 18 de La Habana desde OpenStreetMap.

Mismo origen y estilo que el z17 (tiles.openstreetmap.org, estilo estandar).
A diferencia del script de z17 NO borra la carpeta: se puede reanudar, ya que
los tiles que ya existen y son PNG validos se saltan.
"""
import os
import math
import time
import ssl
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

HAVANA_BOUNDS = {
    'min_lat': 22.90,
    'max_lat': 23.30,
    'min_lon': -82.60,
    'max_lon': -82.00,
}

ZOOM = 18
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
    path = os.path.join(TILES_DIR, str(z), str(x), "%d.png" % y)
    if os.path.exists(path) and os.path.getsize(path) > 100:
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
            if e.code in (429, 403, 504):
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

    tiles = [(z, x, y) for x in range(x_min, x_max + 1) for y in range(y_min, y_max + 1)]
    total = len(tiles)
    print("Descargando %d tiles z%d desde OpenStreetMap (%d hilos)" % (total, z, MAX_WORKERS), flush=True)

    ok = errors = skipped = 0
    failed = []
    start = time.time()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futs = {ex.submit(download_tile, z, x, y): (x, y) for z, x, y in tiles}
        done = 0
        for fut in as_completed(futs):
            r = fut.result()
            if r == 'ok':
                ok += 1
            elif r == 'skip':
                skipped += 1
            else:
                errors += 1
                failed.append(futs[fut])
            done += 1
            if done % 500 == 0 or done == total:
                el = time.time() - start
                sp = done / el if el else 0
                eta = (total - done) / sp if sp else 0
                print("\r  [%5.1f%%] %d/%d OK %d ERR %d SKIP %d %.1f t/s ETA %.0f min" % (
                    done / total * 100, done, total, ok, errors, skipped, sp, eta / 60), end='', flush=True)

    el = time.time() - start
    print("\n\nz%d completado en %.1f min | OK %d | Errores %d | Saltados %d" % (
        z, el / 60, ok, errors, skipped))
    on_disk = sum(len(f) for _, _, f in os.walk(os.path.join(TILES_DIR, str(z))))
    print("Tiles en disco z%d: %d de %d" % (z, on_disk, total))
    if failed:
        with open(os.path.join(os.path.dirname(__file__), 'z18_fallidas.txt'), 'w') as f:
            for x, y in failed:
                f.write('%d/%d\n' % (x, y))
        print("Lista de fallidas escrita en z18_fallidas.txt (%d)" % len(failed))


if __name__ == '__main__':
    main()
