import http.server
import os
import socketserver
from urllib.parse import urlparse

TILES_DIR = os.path.join(os.path.dirname(__file__), '..', 'tiles')
WEB_DIR = os.path.join(os.path.dirname(__file__), '..')
PORT = 8080

class HybridHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path.startswith('/tiles/'):
            parts = parsed.path.split('/')
            if len(parts) >= 5:
                try:
                    z, x, y_ext = parts[2], parts[3], parts[4]
                    local_path = os.path.join(TILES_DIR, z, x, y_ext)

                    if os.path.exists(local_path):
                        self.send_response(200)
                        self.send_header('Content-Type', 'image/png')
                        self.send_header('Cache-Control', 'public, max-age=31536000')
                        self.end_headers()
                        with open(local_path, 'rb') as f:
                            self.wfile.write(f.read())
                        return
                except:
                    pass

            self.send_response(404)
            self.end_headers()
            return

        super().do_GET()

    def log_message(self, format, *args):
        pass

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

def main():
    print(f"Servidor iniciado en http://localhost:{PORT}")
    print(f"Tiles locales: {os.path.abspath(TILES_DIR)}")

    with ReusableTCPServer(("", PORT), HybridHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServidor detenido.")

if __name__ == '__main__':
    main()
