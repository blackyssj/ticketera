#!/usr/bin/env python3
"""Helper compartido para hablar con las APIs de Supabase sin subprocess.

Antes cada script armaba un `curl -H "Authorization: Bearer <secreto>" ...`
por `subprocess.run`. Esos argumentos quedan en el argv del proceso hijo, y
argv es público en la máquina: cualquier otro proceso lo lee con
`ps auxww` o `/proc/<pid>/cmdline`. Para el PAT es molesto; para la
service_role key — la que se salta RLS en todo el proyecto — es grave.

`urllib.request` de la stdlib hace la misma llamada HTTP sin abrir un
subproceso: el secreto viaja solo en la cabecera del pedido del propio
proceso Python, nunca en un argv ajeno.

Lo importan scripts/sql.py, scripts/crear-usuario.py,
scripts/desplegar-funciones.py y scripts/subir-arte.py.
"""
import json, os, pathlib, sys
import urllib.error, urllib.request

REF = os.environ.get("TICKETERA_REF", "mjotxzcddhqqpuhkcetl")


def pat() -> str:
    if os.environ.get("SUPABASE_PAT"):
        return os.environ["SUPABASE_PAT"].strip()
    f = pathlib.Path.home() / ".supabase_pat"
    if f.exists():
        return f.read_text().strip()
    sys.exit("Falta el PAT. Exportá SUPABASE_PAT o dejalo en ~/.supabase_pat")


def request(url, metodo="GET", cabeceras=None, cuerpo=None):
    """cuerpo: str, bytes o None. Devuelve (código:str, cuerpo:str)."""
    datos = cuerpo.encode() if isinstance(cuerpo, str) else cuerpo
    headers = {"User-Agent": "ticketera-scripts/1.0"}
    headers.update(cabeceras or {})
    req = urllib.request.Request(url, data=datos, method=metodo, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            return str(r.status), r.read().decode()
    except urllib.error.HTTPError as e:
        return str(e.code), e.read().decode()
    except urllib.error.URLError as e:
        return "000", str(e.reason)


def service_key(token: str) -> str:
    code, body = request(f"https://api.supabase.com/v1/projects/{REF}/api-keys",
                         cabeceras={"Authorization": f"Bearer {token}"})
    if code not in ("200", "201"):
        sys.exit(f"No pude leer las api-keys: {body[:200]}")
    for k in json.loads(body):
        if k.get("name") == "service_role":
            return k["api_key"]
    sys.exit("No encontré la service_role key")
