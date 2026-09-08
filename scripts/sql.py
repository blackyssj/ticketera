#!/usr/bin/env python3
"""Corre un .sql contra el proyecto de la ticketera por la API de gestión de
Supabase. Existe porque la CLI de Supabase pide login por navegador y esto
funciona con un PAT.

    export SUPABASE_PAT=...          # o dejarlo en ~/.supabase_pat
    python3 scripts/sql.py supabase/tests/invariantes.sql
"""
import json, pathlib, sys

from _api import REF, pat, request


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit("Uso: python3 scripts/sql.py archivo.sql")
    # encoding explicito: en Windows read_text() usa cp1252 y revienta con un
    # UnicodeDecodeError en cualquier .sql que traiga un caracter de dibujo de
    # cajas. Peor todavia cuando NO revienta: los acentos de las migraciones
    # pasan como mojibake, y si van adentro de un string literal eso se guarda
    # asi en la base.
    sql = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    codigo, cuerpo = request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query", "POST",
        {"Authorization": f"Bearer {pat()}", "Content-Type": "application/json"},
        json.dumps({"query": sql}))
    ok = codigo in ("200", "201")
    print(("OK  " if ok else "FALLO  ") + cuerpo[:800])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
