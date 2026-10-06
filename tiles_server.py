"""
Servidor local de tiles para las apps Flutter de TaxiRapid.

Sirve los tiles de E:\\Taxi_Rapid\\HavanaTaxiMap\\tiles en formato
{z}/{x}/{y}.png bajo la ruta /tiles/.

Ejecucion:
    python tiles_server.py [puerto]

Ejemplo de URL servida:
    http://localhost:8010/tiles/16/17731/28404.png
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TILES_ROOT = os.path.join(BASE_DIR, "HavanaTaxiMap", "tiles")


class TileHandler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = unquote(self.path.split("?")[0])

        allowed_prefix = "/tiles/"
        if not path.startswith(allowed_prefix):
            self.send_error(404, "Not found")
            return

        rel_path = path[len(allowed_prefix):]
        # Seguridad: no permitir rutas que escapen de la carpeta de tiles
        normalized = os.path.normpath(rel_path)
        if normalized.startswith("..") or os.path.isabs(normalized):
            self.send_error(403, "Forbidden")
            return

        file_path = os.path.join(TILES_ROOT, normalized)
        if not os.path.isfile(file_path):
            self.send_error(404, "Tile not found")
            return

        ext = os.path.splitext(file_path)[1].lower()
        content_type = {
            ".png": "image/png",
            ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg",
            ".webp": "image/webp",
        }.get(ext, "application/octet-stream")

        try:
            with open(file_path, "rb") as f:
                data = f.read()
        except OSError:
            self.send_error(500, "Error reading tile")
            return

        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=2592000")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stdout.write("[tiles] %s - %s\n" % (self.address_string(), fmt % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8010
    if not os.path.isdir(TILES_ROOT):
        print(f"ERROR: No existe la carpeta de tiles: {TILES_ROOT}")
        sys.exit(1)
    server = ThreadingHTTPServer(("0.0.0.0", port), TileHandler)
    print(f"Sirviendo tiles de {TILES_ROOT}")
    print(f"URL base: http://localhost:{port}/tiles/{{z}}/{{x}}/{{y}}.png")
    print("Deten con Ctrl+C")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()