#!/usr/bin/env python3
"""Corre un .sql contra el proyecto de la ticketera por la API de gestión de
Supabase. Existe porque la CLI de Supabase pide login por navegador y esto
funciona con un PAT.

    export SUPABASE_PAT=...          # o dejarlo en ~/.supabase_pat
    python3 scripts/sql.py supabase/tests/invariantes.sql
    python3 scripts/sql.py consulta.sql --salida datos.json   # la respuesta entera

Sin `--salida` la respuesta sale RECORTADA a 800 caracteres, para que un
select de mil filas no tape la terminal. Eso está bien para verificar que
algo corrió y mal para leer datos: `> archivo.json` desde la shell guarda
el recorte, no la respuesta, y el JSON llega partido a la mitad sin que
nada avise. `--salida` escribe el cuerpo completo, en UTF-8 explícito —en
Windows la redirección de PowerShell guarda UTF-16 y después nada lo puede
leer.
"""
import json, pathlib, sys

from _api import REF, pat, request


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit("Uso: python3 scripts/sql.py archivo.sql [--salida datos.json]")
    salida = None
    if "--salida" in sys.argv:
        i = sys.argv.index("--salida")
        if i + 1 >= len(sys.argv):
            sys.exit("--salida necesita un archivo donde escribir")
        salida = pathlib.Path(sys.argv[i + 1])
        del sys.argv[i:i + 2]
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
    if salida and ok:
        salida.write_text(cuerpo, encoding="utf-8")
        n = len(json.loads(cuerpo)) if cuerpo.lstrip().startswith("[") else None
        print(f"OK  {salida}" + (f"  ({n} filas)" if n is not None else ""))
        return 0
    print(("OK  " if ok else "FALLO  ") + cuerpo[:800])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
