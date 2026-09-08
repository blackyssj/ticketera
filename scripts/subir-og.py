#!/usr/bin/env python3
"""Arma la imagen para el link de WhatsApp y se la pone al evento.

    python3 scripts/subir-og.py distrito-ferial viernes-18 ~/Downloads/previa.jpg
    python3 scripts/subir-og.py distrito-ferial viernes-18        # usa el flyer que ya tiene

El flyer es vertical (9:16): hecho para la historia de Instagram. La tarjeta
de WhatsApp es cuadrada y chica, y un 9:16 ahí sale recortado por el medio:
se pierden la fecha de arriba y el nombre de abajo, que es justo lo que la
tarjeta tenía que decir. O peor, sale como un thumbnail de dos centímetros.

Esto compone un cuadrado de 1200×1200 con el flyer ENTERO adentro, centrado,
sobre el mismo flyer desenfocado y oscurecido para rellenar los costados —
así no quedan dos bandas lisas que se lean como "imagen mal cortada". Lo
sube a Storage con nombre nuevo (el navegador y WhatsApp cachean por URL:
un nombre nuevo es lo que hace que el cambio se vea) y lo guarda en
eventos.og_url, que la función `og` prefiere al flyer.

Sin imagen por argumento usa el flyer que el evento ya tiene: es el caso de
"el cliente lo subió desde el panel, ahora armame la del link".
"""
import datetime, io, json, pathlib, sys
from urllib.parse import quote

from PIL import Image, ImageFilter, ImageEnhance

from _api import REF, pat, request, service_key

LADO = 1200                 # cuadrado: es lo que WhatsApp muestra sin recortar
TOPE_BYTES = 550_000        # WhatsApp deja de mostrar imágenes de más de ~600 KB


def componer(original: Image.Image, fondo_hex=None) -> bytes:
    img = original.convert("RGB")
    lienzo = Image.new("RGB", (LADO, LADO), fondo_hex or "#0B0A0A")

    # El relleno: el mismo flyer llevado a cubrir el cuadrado, desenfocado y
    # oscurecido. Da textura de la misma paleta sin competir con el flyer.
    w, h = img.size
    escala = max(LADO / w, LADO / h)
    relleno = img.resize((round(w * escala), round(h * escala)), Image.LANCZOS)
    relleno = relleno.filter(ImageFilter.GaussianBlur(28))
    relleno = ImageEnhance.Brightness(relleno).enhance(0.45)
    lienzo.paste(relleno, ((LADO - relleno.width) // 2, (LADO - relleno.height) // 2))

    # El flyer entero, a la altura del cuadrado, centrado.
    escala = min(LADO / w, LADO / h)
    frente = img.resize((round(w * escala), round(h * escala)), Image.LANCZOS)
    lienzo.paste(frente, ((LADO - frente.width) // 2, (LADO - frente.height) // 2))

    # JPEG bajo el tope de WhatsApp: se baja la calidad hasta que entre.
    for calidad in (88, 82, 76, 70, 62):
        buf = io.BytesIO()
        lienzo.save(buf, "JPEG", quality=calidad, optimize=True, progressive=True)
        if buf.tell() <= TOPE_BYTES:
            break
    return buf.getvalue()


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit("Uso: subir-og.py <organizador> <evento> [imagen]")
    org_slug, ev_slug = sys.argv[1], sys.argv[2]
    ruta = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None

    srv = service_key(pat())
    base = f"https://{REF}.supabase.co"
    h = {"apikey": srv, "Authorization": f"Bearer {srv}"}
    org_q, ev_q = quote(org_slug, safe=""), quote(ev_slug, safe="")

    org = json.loads(request(f"{base}/rest/v1/organizadores?slug=eq.{org_q}&select=id",
                             cabeceras=h)[1] or "[]")
    if not org:
        sys.exit(f"No existe el organizador '{org_slug}'")
    ev = json.loads(request(
        f"{base}/rest/v1/eventos?organizador_id=eq.{org[0]['id']}&slug=eq.{ev_q}"
        f"&select=id,flyer_url,color_fondo", cabeceras=h)[1] or "[]")
    if not ev:
        sys.exit(f"No existe el evento '{ev_slug}'")
    ev = ev[0]

    if ruta:
        if not ruta.exists():
            sys.exit(f"No existe {ruta}")
        crudo = ruta.read_bytes()
    else:
        if not ev.get("flyer_url"):
            sys.exit("El evento no tiene flyer y no me pasaste una imagen.")
        # request() de _api.py decodifica a texto; una imagen se baja aparte.
        import urllib.request
        with urllib.request.urlopen(ev["flyer_url"]) as r:
            crudo = r.read()
    original = Image.open(io.BytesIO(crudo))
    print(f"original: {original.width}×{original.height}")

    salida = componer(original, ev.get("color_fondo"))
    print(f"compuesta: {LADO}×{LADO}, {len(salida)//1024} KB")

    # Nombre nuevo en cada subida: WhatsApp y Facebook cachean por URL, y con
    # el mismo nombre seguirían mostrando la anterior por días.
    sello = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    destino = f"{org_q}/{ev_q}/og-{sello}.jpg"
    codigo, body = request(f"{base}/storage/v1/object/arte/{destino}", "POST",
                           {**h, "Content-Type": "image/jpeg", "x-upsert": "true",
                            "cache-control": "max-age=31536000"}, salida)
    if codigo not in ("200", "201"):
        sys.exit(f"No se pudo subir: {body[:300]}")
    url = f"{base}/storage/v1/object/public/arte/{destino}"

    request(f"{base}/rest/v1/eventos?id=eq.{ev['id']}", "PATCH",
            {**h, "Content-Type": "application/json"}, json.dumps({"og_url": url}))
    print("og_url del evento actualizado")
    print(url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
