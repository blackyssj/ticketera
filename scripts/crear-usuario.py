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
import json, os, pathlib, secrets, string, subprocess, sys

REF = os.environ.get("TICKETERA_REF", "mjotxzcddhqqpuhkcetl")
ROLES = ("admin", "staff", "rrpp")


def pat() -> str:
    if os.environ.get("SUPABASE_PAT"):
        return os.environ["SUPABASE_PAT"].strip()
    f = pathlib.Path.home() / ".supabase_pat"
    if f.exists():
        return f.read_text().strip()
    sys.exit("Falta el PAT. Exportá SUPABASE_PAT o dejalo en ~/.supabase_pat")


def curl(url, metodo="GET", cabeceras=None, cuerpo=None):
    args = ["curl", "-s", "-w", "\n%{http_code}", "-X", metodo, url]
    for k, v in (cabeceras or {}).items():
        args += ["-H", f"{k}: {v}"]
    if cuerpo is not None:
        args += ["--data-binary", "@-"]
    p = subprocess.run(args, input=cuerpo, capture_output=True, text=True)
    body, _, code = p.stdout.rpartition("\n")
    return code.strip(), body


def service_key(token: str) -> str:
    code, body = curl(f"https://api.supabase.com/v1/projects/{REF}/api-keys",
                      cabeceras={"Authorization": f"Bearer {token}"})
    if code not in ("200", "201"):
        sys.exit(f"No pude leer las api-keys: {body[:200]}")
    for k in json.loads(body):
        if k.get("name") == "service_role":
            return k["api_key"]
    sys.exit("No encontré la service_role key")


def main() -> int:
    if len(sys.argv) < 5:
        sys.exit("Uso: crear-usuario.py <organizador-slug> <usuario> <nombre> <rol>")
    org_slug, usuario, nombre, rol = sys.argv[1:5]
    if rol not in ROLES:
        sys.exit(f"Rol inválido. Alguno de: {', '.join(ROLES)}")

    token = pat()
    srv = service_key(token)
    base = f"https://{REF}.supabase.co"
    h = {"apikey": srv, "Authorization": f"Bearer {srv}",
         "Content-Type": "application/json"}

    code, body = curl(f"{base}/rest/v1/organizadores?slug=eq.{org_slug}&select=id",
                      cabeceras=h)
    filas = json.loads(body or "[]")
    if not filas:
        sys.exit(f"No existe el organizador '{org_slug}'")
    org_id = filas[0]["id"]

    alfabeto = string.ascii_letters + string.digits
    clave = "".join(secrets.choice(alfabeto) for _ in range(14))

    code, body = curl(f"{base}/auth/v1/admin/users", "POST", h, json.dumps({
        "email": f"{usuario}@ticketera.local",
        "password": clave,
        "email_confirm": True,
    }))
    if code not in ("200", "201"):
        sys.exit(f"No pude crear el usuario: {body[:300]}")
    uid = json.loads(body)["id"]

    code, body = curl(f"{base}/rest/v1/perfiles", "POST",
                      {**h, "Prefer": "return=representation"},
                      json.dumps({"id": uid, "organizador_id": org_id,
                                  "nombre": nombre, "rol": rol}))
    if code not in ("200", "201"):
        sys.exit(f"Usuario creado pero sin perfil: {body[:300]}")

    print(f"usuario:  {usuario}")
    print(f"clave:    {clave}")
    print(f"rol:      {rol}")
    print("Anotala ahora: no se puede recuperar, solo resetear.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
