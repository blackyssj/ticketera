#!/usr/bin/env python3
"""Crea una cuenta del staff. El registro público está cerrado a propósito,
así que las cuentas se crean desde acá (o desde la pantalla de Equipo, que
llega en el bloque 4c).

    export SUPABASE_PAT=...
    python3 scripts/crear-usuario.py amstel jose "Jose Menacho" admin

El correo es sintético: <usuario>@ticketera.local. No se usa para nada más
que como identificador de Supabase — no hay recuperación por correo, y eso
fue una decisión, no un olvido.

'portero' no está en la lista: el check de perfiles.rol todavía no lo acepta
(llega con el bloque de la puerta). Agregarlo acá sin esa migración hace que
el alta falle justo en el insert de perfiles.
"""
import json, re, secrets, string, sys
from urllib.parse import quote

from _api import REF, pat, request, service_key

ROLES = ("admin", "staff", "rrpp")
USUARIO_RE = re.compile(r"^[a-z0-9.-]{3,30}$")


def main() -> int:
    if len(sys.argv) < 5:
        sys.exit("Uso: crear-usuario.py <organizador-slug> <usuario> <nombre> <rol>")
    org_slug, usuario, nombre, rol = sys.argv[1:5]
    if rol not in ROLES:
        sys.exit(f"Rol inválido. Alguno de: {', '.join(ROLES)}")
    if not USUARIO_RE.match(usuario):
        sys.exit("Usuario inválido: solo minúsculas, números, '.' y '-', "
                  "entre 3 y 30 caracteres.")

    token = pat()
    srv = service_key(token)
    base = f"https://{REF}.supabase.co"
    h = {"apikey": srv, "Authorization": f"Bearer {srv}",
         "Content-Type": "application/json"}

    code, body = request(f"{base}/rest/v1/organizadores?slug=eq.{quote(org_slug, safe='')}&select=id",
                         cabeceras=h)
    filas = json.loads(body or "[]")
    if not filas:
        sys.exit(f"No existe el organizador '{org_slug}'")
    org_id = filas[0]["id"]

    alfabeto = string.ascii_letters + string.digits
    clave = "".join(secrets.choice(alfabeto) for _ in range(14))

    code, body = request(f"{base}/auth/v1/admin/users", "POST", h, json.dumps({
        "email": f"{usuario}@ticketera.local",
        "password": clave,
        "email_confirm": True,
    }))
    if code not in ("200", "201"):
        sys.exit(f"No pude crear el usuario: {body[:300]}")
    uid = json.loads(body)["id"]

    code, body = request(f"{base}/rest/v1/perfiles", "POST",
                         {**h, "Prefer": "return=representation"},
                         json.dumps({"id": uid, "organizador_id": org_id,
                                     "nombre": nombre, "rol": rol}))
    if code not in ("200", "201"):
        sys.exit(f"Usuario creado (uid={uid}) pero sin perfil: {body[:300]}")

    print(f"usuario:  {usuario}")
    print(f"clave:    {clave}")
    print(f"rol:      {rol}")
    print("Anotala ahora: no se puede recuperar, solo resetear.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
