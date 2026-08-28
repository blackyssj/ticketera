#!/usr/bin/env python3
"""Dos porteros escanean el mismo QR al mismo tiempo. Entra uno solo.

    python3 supabase/tests/carrera-puerta.py

Por qué esto no vive en policies.sql: ese archivo entero corre adentro de
un `begin;` que termina en `rollback;`, y dos sesiones no se ven los datos
de la otra hasta que alguien commitea. Una carrera probada adentro de una
sola transacción es una carrera secuencial, y un test secuencial de una
carrera no prueba nada. Así que la siembra de acá SÍ se commitea, con un
organizador propio de usar y tirar que el script borra al empezar y al
terminar.

El mecanismo es el del cupo en el bloque 1 (docs/plan-bloque1-base.md,
`concurrencia.sh`): dos sesiones de verdad, en paralelo, y un `pg_sleep`
entre el update y el commit para que la segunda choque contra el bloqueo
de fila en vez de pasarle por al lado. Cambia el transporte — allá era
psql contra una base local, acá son dos POST simultáneos a la API de
gestión, que es la única forma de abrir dos sesiones contra la base real —
pero la forma de la prueba es la misma.

Cada corrida hace dos carreras:

  1) contra `validar_entrada`, que es la que tiene que ganar uno solo;
  2) contra una `validar_entrada_ingenua` que hace select-y-después-update,
     el bug que esta tarea existe para no cometer. Tiene que dejar entrar a
     los dos. Sin este control, una carrera que no llega a chocar da verde
     igual y no prueba nada.

La función ingenua se crea y se borra dentro de la corrida, con otro nombre
para no pisar la buena ni romper el invariante 4.
"""
import json, pathlib, sys, threading, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "scripts"))
from _api import REF, pat, request

URL = f"https://api.supabase.com/v1/projects/{REF}/database/query"
TOKEN = pat()

P = "0c0e0a0a-0c0e-4c0e-8c0e-0000000000"   # prefijo de los uuid de usar y tirar
ORG, EV = P + "01", P + "02"
PA, PB = P + "03", P + "04"                 # los dos porteros
E_OK, E_ING = P + "05", P + "06"            # la entrada de cada carrera
CODE_OK, CODE_ING = "BCDFGH234567", "JKLMNP234567"

ESPERA = 3.0        # lo que la sesión A retiene la fila después del update
ARRANQUE_B = 0.5    # cuánto tarda B en llegar


def sql(texto):
    codigo, cuerpo = request(URL, "POST",
                             {"Authorization": f"Bearer {TOKEN}",
                              "Content-Type": "application/json"},
                             json.dumps({"query": texto}))
    return codigo, cuerpo


def sql_ok(texto, que=""):
    codigo, cuerpo = sql(texto)
    if codigo not in ("200", "201"):
        sys.exit(f"FALLO {que}: {cuerpo[:400]}")
    return json.loads(cuerpo or "[]")


LIMPIAR = f"""
delete from entradas      where organizador_id = '{ORG}';
delete from eventos       where organizador_id = '{ORG}';
delete from auth.users    where id in ('{PA}', '{PB}');
delete from organizadores where id = '{ORG}';
"""

SEMBRAR = f"""
insert into organizadores (id, slug, nombre) values ('{ORG}', 'carrera-puerta', 'Carrera Puerta');
insert into auth.users (id, email) values
  ('{PA}', 'carrera-a@ticketera.local'), ('{PB}', 'carrera-b@ticketera.local');
insert into perfiles (id, organizador_id, nombre, rol) values
  ('{PA}', '{ORG}', 'Portero A', 'portero'), ('{PB}', '{ORG}', 'Portero B', 'portero');
insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
  ('{EV}', '{ORG}', 'carrera-puerta', 'Carrera Puerta', current_date + 10, 'publicado');
insert into entradas (id, organizador_id, evento_id, code, canal, cliente, precio, estado) values
  ('{E_OK}',  '{ORG}', '{EV}', '{CODE_OK}',  'publico', 'La Misma Persona', 100, 'valida'),
  ('{E_ING}', '{ORG}', '{EV}', '{CODE_ING}', 'publico', 'La Misma Persona', 100, 'valida');
"""

# El bug que NO se cometió, para comprobar que la carrera choca de verdad.
INGENUA = f"""
create or replace function validar_entrada_ingenua(p_evento uuid, p_code text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $f$
declare v_estado text; v_id uuid;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;
  -- primero pregunta...
  select estado, id into v_estado, v_id from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento
     and code = upper(trim(p_code));
  if v_estado is null then return jsonb_build_object('resultado','no_existe'); end if;
  if v_estado <> 'valida' then return jsonb_build_object('resultado', v_estado); end if;
  -- ...y despues actualiza. En el medio entra el otro portero.
  update entradas set estado = 'usada', used_at = now(), portero_id = auth.uid()
   where id = v_id;
  return jsonb_build_object('resultado','valida');
end $f$;
revoke execute on function validar_entrada_ingenua(uuid, text) from anon, public;
"""


def sesion(fn, code, quien, dormir_antes, dormir_despues, salida, clave):
    """Una sesión: abre transacción, valida, y RETIENE la fila mientras
    duerme. El commit va después del sleep — ese es todo el punto."""
    texto = f"""
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '{quien}', true);
select pg_sleep({dormir_antes});
with v as materialized (select {fn}('{EV}', '{code}') as respuesta)
select v.respuesta, pg_sleep({dormir_despues}) is null as durmio from v;
commit;
"""
    t0 = time.monotonic()
    codigo, cuerpo = sql(texto)
    salida[clave] = {"codigo": codigo, "cuerpo": cuerpo, "seg": round(time.monotonic() - t0, 2)}


def correr_carrera(fn, code, entrada_id, titulo):
    salida = {}
    hilos = [
        threading.Thread(target=sesion, args=(fn, code, PA, 0.0, ESPERA, salida, "A")),
        threading.Thread(target=sesion, args=(fn, code, PB, ARRANQUE_B, 0.0, salida, "B")),
    ]
    t0 = time.monotonic()
    for h in hilos:
        h.start()
    for h in hilos:
        h.join()
    total = round(time.monotonic() - t0, 2)

    def respuesta(k):
        d = salida[k]
        if d["codigo"] not in ("200", "201"):
            return f"ERROR {d['codigo']} {d['cuerpo'][:120]}"
        filas = json.loads(d["cuerpo"] or "[]")
        return (filas[0].get("respuesta") or {}).get("resultado") if filas else None

    ra, rb = respuesta("A"), respuesta("B")
    fila = sql_ok(f"""select estado, used_at, portero_id,
                             (used_at is not null)::int as tiene_hora
                        from entradas where id = '{entrada_id}';""")[0]

    print(f"  {titulo}")
    print(f"    A -> {ra!r:12s} ({salida['A']['seg']}s)   B -> {rb!r:12s} ({salida['B']['seg']}s)"
          f"   total {total}s")
    print(f"    fila: estado={fila['estado']} used_at={'si' if fila['tiene_hora'] else 'no'} "
          f"portero={'A' if fila['portero_id'] == PA else 'B' if fila['portero_id'] == PB else fila['portero_id']}")
    return ra, rb, fila, salida["B"]["seg"]


def main():
    sql_ok(LIMPIAR, "limpieza previa")
    sql_ok(SEMBRAR, "siembra")
    fallos = []
    try:
        print("Dos porteros, el mismo QR, al mismo tiempo:\n")

        # ── 1) la buena ────────────────────────────────────
        ra, rb, fila, seg_b = correr_carrera("validar_entrada", CODE_OK, E_OK,
                                             "validar_entrada (update condicional)")
        ganadores = [r for r in (ra, rb) if r == "valida"]
        if len(ganadores) != 1:
            fallos.append(f"entraron {len(ganadores)} de 1: A={ra!r} B={rb!r}")
        if sorted([ra or "", rb or ""]) != ["usada", "valida"]:
            fallos.append(f"el que perdio tenia que recibir 'usada': A={ra!r} B={rb!r}")
        if fila["estado"] != "usada" or not fila["tiene_hora"]:
            fallos.append(f"la fila quedo mal: {fila}")

        # La prueba de que la carrera CHOCÓ: B se quedó esperando el lock
        # de A. Si B contestara al instante, las dos sesiones no se habrian
        # cruzado y el verde de arriba no significaria nada.
        espera_minima = ESPERA - ARRANQUE_B - 0.5
        if seg_b < espera_minima:
            fallos.append(f"B contesto en {seg_b}s: no llego a chocar contra el lock de A "
                          f"(tenia que esperar al menos {espera_minima:.1f}s). "
                          f"Las dos sesiones no corrieron en paralelo.")
        else:
            print(f"    B espero {seg_b}s por el lock de A: la carrera fue real\n")

        # ── 2) el control negativo ─────────────────────────
        sql_ok(INGENUA, "crear la ingenua")
        try:
            ra2, rb2, fila2, _ = correr_carrera("validar_entrada_ingenua", CODE_ING, E_ING,
                                                "validar_entrada_ingenua (select y despues update)")
            colados = [r for r in (ra2, rb2) if r == "valida"]
            if len(colados) != 2:
                fallos.append("CONTROL_INUTIL: la version ingenua NO dejo entrar a los dos "
                              f"(A={ra2!r} B={rb2!r}). Si el bug no se reproduce, el verde de "
                              "la carrera buena no prueba que el update condicional sea lo que salva.")
            else:
                print("    entraron los DOS, como tenia que pasar: el harness detecta el bug\n")
        finally:
            sql_ok("drop function if exists validar_entrada_ingenua(uuid, text);", "borrar la ingenua")
    finally:
        sql_ok(LIMPIAR, "limpieza final")

    if fallos:
        for f in fallos:
            print("TEST_FAIL: " + f)
        return 1
    print("OK dos porteros escanean el mismo QR a la vez y entra uno solo, con una sola hora")
    return 0


if __name__ == "__main__":
    sys.exit(main())
