#!/usr/bin/env python3
"""Los pedidos de "quiero vender con TICKETAZO", desde la terminal.

La tabla `contactos` no la lee nadie por RLS —ni siquiera un admin de un
organizador, que no tiene por qué ver a quién más le cotizamos—. Se lee de
acá, con el PAT, como todo lo demás de scripts/.

    python3 scripts/contactos.py            # los últimos 30
    python3 scripts/contactos.py nuevos     # sólo los que nadie tocó
    python3 scripts/contactos.py marcar <id> contactado|cerrado|descartado
"""
import json, os, pathlib, subprocess, sys, tempfile

AQUI = pathlib.Path(__file__).resolve().parent

def sql(consulta):
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(consulta); ruta = f.name
    try:
        out = subprocess.run([sys.executable, str(AQUI / "sql.py"), ruta],
                             capture_output=True, text=True).stdout
    finally:
        os.unlink(ruta)
    if not out.startswith("OK"):
        sys.exit(out.strip() or "sql.py no contestó")
    cuerpo = out[out.index("[") : out.rindex("]") + 1] if "[" in out else "[]"
    return json.loads(cuerpo)

def listar(solo_nuevos):
    filtro = "where estado = 'nuevo'" if solo_nuevos else ""
    filas = sql(f"""
      select id::text, to_char(creado_at at time zone 'America/La_Paz','DD Mon HH24:MI') cuando,
             estado, nombre, contacto, coalesce(evento,'') evento,
             coalesce(fecha_evento::text,'') fecha, coalesce(lugar,'') lugar,
             coalesce(publico::text,'') publico, coalesce(mensaje,'') mensaje, origen
        from contactos {filtro} order by creado_at desc limit 30;""")
    if not filas:
        print("Sin pedidos." if not solo_nuevos else "Nada nuevo."); return
    for f in filas:
        print(f"{f['cuando']}  [{f['estado']:<10}]  {f['nombre']} · {f['contacto']}")
        if f['evento'] or f['fecha'] or f['lugar'] or f['publico']:
            print(f"    {f['evento']}  {f['fecha']}  {f['lugar']}  {f['publico'] and f['publico']+' personas'}")
        if f['mensaje']:
            print(f"    «{f['mensaje'][:140]}»")
        print(f"    id {f['id']}  · vía {f['origen']}")

def marcar(id_, estado):
    if estado not in ("contactado", "cerrado", "descartado", "nuevo"):
        sys.exit("estado: contactado | cerrado | descartado | nuevo")
    n = sql(f"update contactos set estado = '{estado}' where id = '{id_}' returning id::text;")
    print("marcado" if n else "no existe ese id")

if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:                 listar(False)
    elif a[0] == "nuevos":    listar(True)
    elif a[0] == "marcar" and len(a) == 3: marcar(a[1], a[2])
    else: sys.exit(__doc__)
