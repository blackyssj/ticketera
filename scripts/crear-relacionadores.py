#!/usr/bin/env python3
"""Da de alta VARIOS relacionadores de una, desde una lista en un archivo.

    python3 scripts/crear-relacionadores.py distrito-ferial mi-lista.txt

El archivo tiene una persona por línea, separada por comas:

    usuario, Nombre Completo, codigo, comision, correo
    nico,    Nicolás Áñez,    nico,   15,       nico@gmail.com
    cami,    Camila Ortiz,    cami

  · usuario   entra a /admin. Minúsculas, 3 a 30, letras/números/. y -
  · nombre    como se lo ve en el panel y en los reportes
  · codigo    va en su link personal (?r=<codigo>). Puede omitirse.
  · comision  Bs POR ENTRADA vendida. Vacío = la del evento (hoy 15 Bs).
  · correo    el suyo de verdad, para mandarle el link. Puede omitirse.
              OJO: no es con lo que entra al panel — eso es el usuario.

Líneas en blanco y las que empiezan con # se ignoran, así que la lista se
puede comentar.

Por qué existe teniendo `crear-usuario.py` al lado: ese script no pone ni
el código ni la comisión, que es justo lo que distingue a un relacionador
de cualquier otra cuenta. Uno creado con él queda sin link propio y
cobrando la comisión por defecto del evento, y eso se descubre el día del
evento cuando alguien reclama su plata.

Y por qué no usa la Edge Function `equipo`, que sí hace todo esto: esa
pide el token de una sesión de admin abierta en el navegador. Este corre
con el PAT, como el resto de scripts/.

── el orden importa ────────────────────────────────────────────
Valida TODA la lista contra la base antes de crear a nadie. Con treinta
personas, morirse en la número diecinueve deja media lista adentro, la
otra media afuera, y a vos adivinando cuál era cuál — porque las claves
de las que sí entraron ya se imprimieron y las de las que no, no existen.
Mejor fallar entera y sin haber tocado nada.
"""
import csv, datetime, json, pathlib, re, secrets, string, sys, unicodedata
from urllib.parse import quote

from _api import REF, pat, request, service_key

USUARIO_RE = re.compile(r"^[a-z0-9.-]{3,30}$")
SLUG_RE    = re.compile(r"^[a-z0-9-]{2,30}$")
# El mismo criterio flojo que el check de 0072 y que la Edge Function: lo
# que hay que atrapar es un nombre o un telefono escrito en esa columna,
# no una direccion rara pero valida.
CORREO_RE  = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def leer(ruta: pathlib.Path):
    """El archivo a filas ya limpias. Falla con el número de línea: una
    lista de treinta con un error en la doce no se arregla si el mensaje
    solo dice «hay un error»."""
    filas, errores = [], []
    for n, linea in enumerate(ruta.read_text(encoding="utf-8").splitlines(), 1):
        linea = linea.strip()
        if not linea or linea.startswith("#"):
            continue
        partes = [p.strip() for p in linea.split(",")]
        if len(partes) < 2:
            errores.append(f"línea {n}: faltan campos — va «usuario, Nombre, codigo, comision, correo»")
            continue
        usuario, nombre = partes[0].lower(), partes[1]
        slug = partes[2].lower() if len(partes) > 2 and partes[2] else None
        com  = partes[3] if len(partes) > 3 and partes[3] else None
        correo = partes[4].lower() if len(partes) > 4 and partes[4] else None

        if not USUARIO_RE.match(usuario):
            errores.append(f"línea {n}: usuario «{usuario}» inválido "
                           "(minúsculas, 3 a 30, letras/números/. y -)")
        if not nombre or len(nombre) > 80:
            errores.append(f"línea {n}: nombre vacío o de más de 80 caracteres")
        if slug and not SLUG_RE.match(slug):
            errores.append(f"línea {n}: código «{slug}» inválido "
                           "(minúsculas, 2 a 30, letras/números y -)")
        if com is not None:
            try:
                com = round(float(com.replace(",", ".")), 2)
                if com < 0:
                    raise ValueError
            except ValueError:
                errores.append(f"línea {n}: comisión «{partes[3]}» no es un monto en Bs")
                com = None
        if correo and not CORREO_RE.match(correo):
            errores.append(f"línea {n}: «{correo}» no tiene forma de correo")
        filas.append({"linea": n, "usuario": usuario, "nombre": nombre,
                      "slug": slug, "comision": com, "correo": correo})
    return filas, errores


def igual(a: str, b: str) -> bool:
    """Dos nombres que son la misma persona. Sin acentos, sin mayúsculas y
    sin espacios de más: la lista viene de un WhatsApp copiado a mano."""
    def limpiar(s):
        s = unicodedata.normalize("NFKD", s or "")
        s = "".join(c for c in s if not unicodedata.combining(c))
        return " ".join(s.lower().split())
    return limpiar(a) == limpiar(b)


def repetidos(filas):
    """Choques adentro del propio archivo. La base los frenaría igual, pero
    recién en el insert — o sea, con la mitad de la lista ya creada."""
    errores, vistos_u, vistos_s = [], {}, {}
    for f in filas:
        if f["usuario"] in vistos_u:
            errores.append(f"línea {f['linea']}: el usuario «{f['usuario']}» "
                           f"ya está en la línea {vistos_u[f['usuario']]}")
        vistos_u.setdefault(f["usuario"], f["linea"])
        if f["slug"]:
            if f["slug"] in vistos_s:
                errores.append(f"línea {f['linea']}: el código «{f['slug']}» "
                               f"ya está en la línea {vistos_s[f['slug']]}")
            vistos_s.setdefault(f["slug"], f["linea"])
    return errores


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit("Uso: crear-relacionadores.py <organizador-slug> <archivo.txt>")
    org_slug, ruta = sys.argv[1], pathlib.Path(sys.argv[2])
    if not ruta.exists():
        sys.exit(f"No encuentro el archivo «{ruta}»")

    filas, errores = leer(ruta)
    errores += repetidos(filas)
    if not filas and not errores:
        sys.exit("El archivo no tiene ninguna persona.")

    token = pat()
    srv = service_key(token)
    base = f"https://{REF}.supabase.co"
    h = {"apikey": srv, "Authorization": f"Bearer {srv}",
         "Content-Type": "application/json"}

    code, body = request(
        f"{base}/rest/v1/organizadores?slug=eq.{quote(org_slug, safe='')}&select=id,nombre",
        cabeceras=h)
    org = json.loads(body or "[]")
    if not org:
        sys.exit(f"No existe el organizador «{org_slug}»")
    org_id, org_nombre = org[0]["id"], org[0].get("nombre", org_slug)

    # Los códigos que ese organizador YA tiene. El unique de 0024 es
    # (organizador_id, slug): el mismo «nico» en otro cliente es legal.
    code, body = request(
        f"{base}/rest/v1/perfiles?organizador_id=eq.{org_id}&select=nombre,slug", cabeceras=h)
    tomados = {p["slug"]: p["nombre"] for p in json.loads(body or "[]") if p.get("slug")}
    # Un código tomado por OTRA persona es un error: hay que elegir otro, y
    # hasta que se elija no se crea nadie. Pero tomado por alguien que se
    # llama igual es un REINTENTO — la corrida anterior llegó hasta ahí y se
    # cortó. Con una lista de cien, obligar a borrar a mano las que ya
    # entraron es pedirle a alguien que edite cien líneas a las tres de la
    # mañana, y ahí es donde se borra la línea equivocada.
    ya_estaban, pendientes = [], []
    for f in filas:
        duenio = tomados.get(f["slug"]) if f["slug"] else None
        if duenio is None:
            pendientes.append(f)
        elif igual(duenio, f["nombre"]):
            ya_estaban.append(f)
        else:
            errores.append(f"línea {f['linea']}: el código «{f['slug']}» ya es de "
                           f"{duenio} en {org_nombre}")
    filas = pendientes

    if errores:
        print(f"No creé a nadie. {len(errores)} problema(s) en la lista:\n")
        for e in errores:
            print("  · " + e)
        return 1

    if ya_estaban:
        print(f"{len(ya_estaban)} ya estaban creadas de antes, las salteo:")
        for f in ya_estaban:
            print(f"  ==  {f['usuario']:<20} {f['nombre']}")
        print()
    if not filas:
        print("No queda nadie por crear.")
        return 0

    print(f"{len(filas)} persona(s) para {org_nombre}. Creando…\n")
    alfabeto = string.ascii_letters + string.digits
    hechos, fallados = [], []

    for f in filas:
        clave = "".join(secrets.choice(alfabeto) for _ in range(14))
        code, body = request(f"{base}/auth/v1/admin/users", "POST", h, json.dumps({
            "email": f"{f['usuario']}@ticketera.local",
            "password": clave, "email_confirm": True}))
        if code not in ("200", "201"):
            motivo = ("el usuario ya está tomado" if code == "422"
                      else f"alta rechazada ({code}): {body[:120]}")
            fallados.append((f["usuario"], motivo))
            continue
        uid = json.loads(body)["id"]

        code, body = request(f"{base}/rest/v1/perfiles", "POST", h, json.dumps({
            "id": uid, "organizador_id": org_id, "nombre": f["nombre"],
            "rol": "rrpp", "slug": f["slug"], "comision_entrada": f["comision"],
            "email_contacto": f["correo"]}))
        if code not in ("200", "201", "204"):
            # Sin perfil no queda nadie a medias: una cuenta de auth sin fila
            # en `perfiles` es, para el sistema, un COMPRADOR — y el usuario
            # queda tomado para siempre sin que nadie sepa de quién es.
            request(f"{base}/auth/v1/admin/users/{uid}", "DELETE", h)
            fallados.append((f["usuario"], f"perfil rechazado ({code}): {body[:120]}"))
            continue

        hechos.append({"usuario": f["usuario"], "clave": clave, "nombre": f["nombre"],
                       "codigo": f["slug"] or "", "comision": f["comision"] or "",
                       "correo": f["correo"] or ""})
        print(f"  ok  {f['usuario']:<20} {f['nombre']}")

    for u, motivo in fallados:
        print(f"  --  {u:<20} {motivo}")

    if not hechos:
        return 1

    # Las claves a un archivo y no sólo a la pantalla: con veinte personas,
    # el scrollback de la terminal es donde las credenciales se pierden. El
    # nombre entra en .gitignore (claves-*.csv).
    salida = pathlib.Path(
        f"claves-{org_slug}-{datetime.date.today():%Y-%m-%d}.csv")
    with salida.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["usuario", "clave", "nombre", "codigo",
                                           "comision", "correo"])
        w.writeheader()
        w.writerows(hechos)

    print(f"\n{len(hechos)} creado(s), {len(fallados)} sin crear.")
    print(f"Claves en {salida} — no se pueden recuperar, sólo resetear desde el panel.")
    print("Pasásela a cada uno por privado y después borrá el archivo.")
    return 0 if not fallados else 1


if __name__ == "__main__":
    sys.exit(main())
