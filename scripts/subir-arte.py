#!/usr/bin/env python3
"""Sube el modelo de la entrada y lo ata al evento o a una fase.

    export SUPABASE_PAT=...
    python3 scripts/subir-arte.py amstel ferial arte.png            # al evento
    python3 scripts/subir-arte.py amstel ferial arte.png "Preventa 2"  # a una fase

El QR se dibuja ENCIMA de esta imagen, en el mismo lugar que en Bowie y
BurTown: caja blanca del 52% del ancho, desde el 29% de la altura. Un arte
hecho para Puerta sirve acá sin rehacerlo.

Dejá esa zona despejada en el diseño, o el QR va a tapar algo.
"""
import json, mimetypes, os, pathlib, subprocess, sys

REF = os.environ.get("TICKETERA_REF", "mjotxzcddhqqpuhkcetl")


def pat() -> str:
    if os.environ.get("SUPABASE_PAT"):
        return os.environ["SUPABASE_PAT"].strip()
    f = pathlib.Path.home() / ".supabase_pat"
    if f.exists():
        return f.read_text().strip()
    sys.exit("Falta el PAT. Exportá SUPABASE_PAT o dejalo en ~/.supabase_pat")


def curl(url, metodo="GET", cabeceras=None, cuerpo=None, archivo=None):
    args = ["curl", "-s", "-w", "\n%{http_code}", "-X", metodo, url]
    for k, v in (cabeceras or {}).items():
        args += ["-H", f"{k}: {v}"]
    if archivo:
        args += ["--data-binary", f"@{archivo}"]
        p = subprocess.run(args, capture_output=True, text=True)
    else:
        if cuerpo is not None:
            args += ["--data-binary", "@-"]
        p = subprocess.run(args, input=cuerpo, capture_output=True, text=True)
    body, _, code = p.stdout.rpartition("\n")
    return code.strip(), body


def service_key(token):
    code, body = curl(f"https://api.supabase.com/v1/projects/{REF}/api-keys",
                      cabeceras={"Authorization": f"Bearer {token}"})
    if code not in ("200", "201"):
        sys.exit(f"No pude leer las api-keys: {body[:200]}")
    for k in json.loads(body):
        if k.get("name") == "service_role":
            return k["api_key"]
    sys.exit("No encontré la service_role key")


def main() -> int:
    if len(sys.argv) < 4:
        sys.exit("Uso: subir-arte.py <organizador> <evento> <imagen> [nombre-de-fase]")
    org_slug, ev_slug, ruta = sys.argv[1:4]
    fase_nombre = sys.argv[4] if len(sys.argv) > 4 else None

    img = pathlib.Path(ruta)
    if not img.exists():
        sys.exit(f"No existe {ruta}")
    tipo = mimetypes.guess_type(str(img))[0] or "image/png"
    if tipo not in ("image/png", "image/jpeg", "image/webp"):
        sys.exit(f"Formato no permitido: {tipo}. Usá png, jpg o webp.")
    if img.stat().st_size > 5 * 1024 * 1024:
        sys.exit("La imagen pasa los 5 MB.")

    srv = service_key(pat())
    base = f"https://{REF}.supabase.co"
    h = {"apikey": srv, "Authorization": f"Bearer {srv}"}

    org = json.loads(curl(f"{base}/rest/v1/organizadores?slug=eq.{org_slug}&select=id",
                          cabeceras=h)[1] or "[]")
    if not org:
        sys.exit(f"No existe el organizador '{org_slug}'")
    ev = json.loads(curl(
        f"{base}/rest/v1/eventos?organizador_id=eq.{org[0]['id']}&slug=eq.{ev_slug}&select=id",
        cabeceras=h)[1] or "[]")
    if not ev:
        sys.exit(f"No existe el evento '{ev_slug}'")

    # La primera carpeta es el organizador: así lo exige la policy del bucket.
    destino = f"{org_slug}/{ev_slug}/{'fase-' + fase_nombre.lower().replace(' ', '-') if fase_nombre else 'evento'}{img.suffix}"
    code, body = curl(f"{base}/storage/v1/object/arte/{destino}", "POST",
                      {**h, "Content-Type": tipo, "x-upsert": "true"}, archivo=str(img))
    if code not in ("200", "201"):
        sys.exit(f"No se pudo subir: {body[:300]}")

    url = f"{base}/storage/v1/object/public/arte/{destino}"

    if fase_nombre:
        r = curl(f"{base}/rest/v1/evento_fase?evento_id=eq.{ev[0]['id']}&nombre=eq."
                 + fase_nombre.replace(" ", "%20"), "PATCH",
                 {**h, "Content-Type": "application/json", "Prefer": "return=representation"},
                 json.dumps({"arte_url": url}))
        if not json.loads(r[1] or "[]"):
            sys.exit(f"Subí la imagen pero no encontré la fase '{fase_nombre}'. URL: {url}")
        print(f"arte de la fase '{fase_nombre}' actualizado")
    else:
        curl(f"{base}/rest/v1/eventos?id=eq.{ev[0]['id']}", "PATCH",
             {**h, "Content-Type": "application/json"}, json.dumps({"arte_url": url}))
        print("arte del evento actualizado")

    print(url)
    print("El QR va sobre el 52% central, desde el 29% de la altura. Dejá esa zona despejada.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
