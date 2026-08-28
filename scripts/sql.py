#!/usr/bin/env python3
"""Corre un .sql contra el proyecto de la ticketera por la API de gestión de
Supabase. Existe porque la CLI de Supabase pide login por navegador y esto
funciona con un PAT.

    export SUPABASE_PAT=...          # o dejarlo en ~/.supabase_pat
    python3 scripts/sql.py supabase/tests/invariantes.sql
"""
import json, os, pathlib, subprocess, sys

REF = os.environ.get("TICKETERA_REF", "mjotxzcddhqqpuhkcetl")

def token() -> str:
    if os.environ.get("SUPABASE_PAT"):
        return os.environ["SUPABASE_PAT"].strip()
    f = pathlib.Path.home() / ".supabase_pat"
    if f.exists():
        return f.read_text().strip()
    sys.exit("Falta el PAT. Exportá SUPABASE_PAT o dejalo en ~/.supabase_pat")

def main() -> int:
    if len(sys.argv) < 2:
        return int(bool(sys.exit("Uso: python3 scripts/sql.py archivo.sql")))
    sql = pathlib.Path(sys.argv[1]).read_text()
    p = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-X", "POST",
         f"https://api.supabase.com/v1/projects/{REF}/database/query",
         "-H", f"Authorization: Bearer {token()}",
         "-H", "Content-Type: application/json", "--data-binary", "@-"],
        input=json.dumps({"query": sql}), capture_output=True, text=True)
    cuerpo, _, codigo = p.stdout.rpartition("\n")
    ok = codigo.strip() in ("200", "201")
    print(("OK  " if ok else "FALLO  ") + cuerpo[:800])
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
