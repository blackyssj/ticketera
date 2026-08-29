#!/usr/bin/env python3
"""Despliega las Edge Functions por la API de gestión.

    export SUPABASE_PAT=...
    python3 scripts/desplegar-funciones.py [nombre ...]

OJO: desplegadas así NO se bundlean, así que las funciones no pueden tener
`import` remotos (`jsr:` ni `https://esm.sh/...`) — dan BOOT_ERROR. Por eso
hablan PostgREST con `fetch` en vez de usar @supabase/supabase-js.
"""
import json, pathlib, sys
from urllib.parse import quote

from _api import REF, pat, request

BASE = pathlib.Path(__file__).resolve().parent.parent / "supabase" / "functions"
TODAS = ["eventos", "evento", "crear-orden", "iniciar-pago", "estado-orden",
         "orden", "enviar-entradas"]

# Por defecto False: eventos, evento, crear-orden, iniciar-pago, estado-orden y
# orden las llama el público con la anon key, sin sesión. enviar-entradas es la
# excepción — solo la llama estado-orden, del lado del servidor, con
# cabeceras de service_role — así que va con JWT exigido. Antes mandaba
# False para las seis por igual; eso la dejaba pública sin que nadie lo
# hubiera decidido.
VERIFY_JWT = {"enviar-entradas": True}

def main() -> int:
    token = pat()
    fallos = 0
    for slug in (sys.argv[1:] or TODAS):
        cuerpo = (BASE / slug / "index.ts").read_text()
        verify_jwt = VERIFY_JWT.get(slug, False)
        carga = json.dumps({"slug": slug, "name": slug, "body": cuerpo, "verify_jwt": verify_jwt})
        h = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        slug_q = quote(slug, safe="")
        for metodo, url in [
            ("POST", f"https://api.supabase.com/v1/projects/{REF}/functions"),
            ("PATCH", f"https://api.supabase.com/v1/projects/{REF}/functions/{slug_q}"),
        ]:
            codigo, resp = request(url, metodo, h, carga)
            if codigo in ("200", "201"):
                print(f"OK    {slug}")
                break
        else:
            print(f"FALLO {slug}  {resp[:250]}")
            fallos += 1
    return 1 if fallos else 0

if __name__ == "__main__":
    sys.exit(main())
