#!/usr/bin/env python3
"""Carga secrets de las Edge Functions desde un archivo .env que NO se versiona.

    python3 scripts/secretos.py ~/.ticketera-pasarela.env
    python3 scripts/secretos.py --listar

El archivo es `CLAVE=valor` por línea, con `#` para comentarios. Los valores
nunca viajan en el argv —solo la ruta del archivo—, porque argv es público en
la máquina: cualquier proceso lo lee con `ps auxww`. Es el mismo motivo por
el que _api.py existe.

`--listar` muestra los nombres y el digest que devuelve Supabase, nunca el
valor. Si necesitás el valor, está en el archivo; la API no lo devuelve.
"""
import json, pathlib, sys

from _api import REF, pat, request


def cargar(ruta: pathlib.Path) -> list[dict]:
    pares = []
    for n, linea in enumerate(ruta.read_text().splitlines(), 1):
        linea = linea.strip()
        if not linea or linea.startswith("#"):
            continue
        if "=" not in linea:
            sys.exit(f"{ruta}:{n}: esperaba CLAVE=valor")
        k, v = linea.split("=", 1)
        k, v = k.strip(), v.strip().strip('"').strip("'")
        if not k:
            sys.exit(f"{ruta}:{n}: falta el nombre")
        pares.append({"name": k, "value": v})
    if not pares:
        sys.exit(f"{ruta} no tiene ningún secreto")
    return pares


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    token = pat()
    url = f"https://api.supabase.com/v1/projects/{REF}/secrets"
    h = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    if sys.argv[1] == "--listar":
        code, body = request(url, cabeceras=h)
        if code != "200":
            sys.exit(f"No pude listar: {body[:300]}")
        for s in json.loads(body):
            print(f"{s['name']:<28} {s.get('updated_at', '')}")
        return 0

    ruta = pathlib.Path(sys.argv[1]).expanduser()
    if not ruta.exists():
        sys.exit(f"No existe {ruta}")
    pares = cargar(ruta)
    code, body = request(url, "POST", h, json.dumps(pares))
    if code not in ("200", "201"):
        sys.exit(f"No pude guardar: {body[:300]}")
    # Solo los nombres. El valor no se imprime ni acá ni en ningún log.
    for p in pares:
        print(f"OK  {p['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
