#!/usr/bin/env python3
"""Sirve app/ en local aplicando los rewrites de app/vercel.json.

    python3 scripts/servir.py            # http://localhost:4174
    python3 scripts/servir.py 8080       # otro puerto

Por qué no alcanza `python3 -m http.server --directory app`: la página de un
evento vive en `/<organizador>/<evento>` y no existe como carpeta. En Vercel
eso lo resuelve un rewrite a `/evento.html`; el servidor de la stdlib no sabe
nada de eso y contesta 404. O sea que en local se podía ver la cartelera pero
NO se podía entrar a ningún evento — justo la pantalla donde se compra.

Y no se puede trampear con un `?evento=`: app.js lee el organizador y el
evento del PATH y de ningún otro lado (ver CFG), a propósito, para que una
ruta rota falle en vez de vender el evento de otro cliente.

Las reglas se leen de app/vercel.json y no están repetidas acá: si alguien
agrega una ruta nueva allá, este servidor la toma sola. Se traduce la sintaxis
de Vercel —`:param` y `(.*)`— a expresiones regulares.

Es sólo para desarrollo: un hilo, sin caché, sin HTTPS.
"""
import http.server
import json
import pathlib
import re
import socketserver
import sys
from urllib.parse import urlparse

RAIZ = pathlib.Path(__file__).resolve().parent.parent / "app"


def reglas():
    """Los rewrites de vercel.json como (regex, destino), en orden.

    El orden importa y es el del archivo: `/:organizador/:evento` matchea
    cualquier par de segmentos, así que tiene que quedar DESPUÉS de las rutas
    fijas como `/admin/(.*)`. Vercel las evalúa en orden y acá igual.
    """
    cfg = json.loads((RAIZ / "vercel.json").read_text(encoding="utf-8"))
    out = []
    for r in cfg.get("rewrites", []):
        patron = r["source"]
        # `:param` toma un segmento; `(.*)` ya es regex y se deja como está.
        patron = re.sub(r":[A-Za-z_][A-Za-z0-9_]*", "[^/]+", patron)
        out.append((re.compile("^" + patron + "$"), r["destination"]))
    return out


REGLAS = reglas()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(RAIZ), **kw)

    def translate_path(self, path):
        limpio = urlparse(path).path
        # Un archivo que existe gana siempre: los rewrites son para lo que no
        # está en disco. Sin esto, `/admin/admin.js` se lo comería la regla
        # `/admin/(.*)` y el panel se quedaría sin su propio código.
        if (RAIZ / limpio.lstrip("/")).is_file():
            return super().translate_path(path)
        for rx, destino in REGLAS:
            if rx.match(limpio):
                return super().translate_path(destino)
        return super().translate_path(path)

    def end_headers(self):
        # Igual que en producción: nada de caché, para que un F5 muestre lo
        # que se acaba de editar y no lo de hace diez minutos.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, formato, *args):
        # Una línea por pedido, sin la fecha, que en una terminal chica sólo
        # empuja la ruta fuera de la pantalla.
        sys.stderr.write("  %s\n" % (formato % args))


def main():
    puerto = int(sys.argv[1]) if len(sys.argv) > 1 else 4174
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", puerto), Handler) as s:
        print(f"app/ en http://localhost:{puerto}")
        print(f"{len(REGLAS)} rewrites tomados de app/vercel.json")
        print("Ctrl+C para cortar")
        try:
            s.serve_forever()
        except KeyboardInterrupt:
            print()


if __name__ == "__main__":
    main()
