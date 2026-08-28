#!/usr/bin/env python3
"""Despliega las Edge Functions por la API de gestión.

    export SUPABASE_PAT=...
    python3 scripts/desplegar-funciones.py [nombre ...]

OJO: desplegadas así NO se bundlean, así que las funciones no pueden tener
`import` remotos (`jsr:` ni `https://esm.sh/...`) — dan BOOT_ERROR. Por eso
hablan PostgREST con `fetch` en vez de usar @supabase/supabase-js.
"""
import json, os, pathlib, subprocess, sys

REF = os.environ.get("TICKETERA_REF", "mjotxzcddhqqpuhkcetl")
BASE = pathlib.Path(__file__).resolve().parent.parent / "supabase" / "functions"
TODAS = ["evento", "crear-orden", "iniciar-pago", "estado-orden",
         "orden", "enviar-entradas"]

def token() -> str:
    if os.environ.get("SUPABASE_PAT"):
        return os.environ["SUPABASE_PAT"].strip()
    f = pathlib.Path.home() / ".supabase_pat"
    if f.exists():
        return f.read_text().strip()
    sys.exit("Falta el PAT. Exportá SUPABASE_PAT o dejalo en ~/.supabase_pat")

def main() -> int:
    pat = token()
    fallos = 0
    for slug in (sys.argv[1:] or TODAS):
        cuerpo = (BASE / slug / "index.ts").read_text()
        carga = json.dumps({"slug": slug, "name": slug, "body": cuerpo, "verify_jwt": False})
        for metodo, url in [
            ("POST", f"https://api.supabase.com/v1/projects/{REF}/functions"),
            ("PATCH", f"https://api.supabase.com/v1/projects/{REF}/functions/{slug}"),
        ]:
            p = subprocess.run(
                ["curl", "-s", "-w", "\n%{http_code}", "-X", metodo, url,
                 "-H", f"Authorization: Bearer {pat}",
                 "-H", "Content-Type: application/json", "--data-binary", "@-"],
                input=carga, capture_output=True, text=True)
            resp, _, codigo = p.stdout.rpartition("\n")
            if codigo.strip() in ("200", "201"):
                print(f"OK    {slug}")
                break
        else:
            print(f"FALLO {slug}  {resp[:250]}")
            fallos += 1
    return 1 if fallos else 0

if __name__ == "__main__":
    sys.exit(main())
