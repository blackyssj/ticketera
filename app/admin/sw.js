/* ══════════════════════════════════════════════════════════════════
   El service worker de la puerta: que la pantalla ABRA sin internet.

   Antes que cualquier lógica de escaneo sin señal está esto, que es lo
   que casi siempre se olvida: si el portero recarga la página en la
   feria y no hay wifi, no hay pantalla. No es que falle el escaneo —
   no carga ni el HTML, ni admin.js, ni jsQR, y el teléfono muestra el
   dinosaurio. Toda la lógica offline del mundo no sirve si la
   aplicación no arranca.

   Alcance: sólo /admin/. La landing y la venta se sirven de la red como
   siempre; cachearlas dejaría a un comprador viendo precios viejos.

   ── lo que NUNCA se cachea ──────────────────────────────────
   Nada de *.supabase.co. Esas son las llamadas a la base: el conteo, la
   validación, el padrón. Servir una respuesta guardada ahí significa
   dejar entrar a alguien contra una lista de hace dos horas creyendo
   que es la de ahora, que es peor que no tener nada. La lista offline
   se guarda a propósito y aparte, con su hora a la vista (puerta.js).

   ── por qué el cache-miss reintenta sin el ?v= ──────────────
   El shell se guarda con la versión que tiene el HTML hoy
   (admin.js?v=31). Cuando alguien sube el `?v=` y no toca la lista de
   acá, el pedido nuevo no matchea nada guardado y offline no habría
   pantalla. El segundo intento con `ignoreSearch` sirve la copia vieja:
   una versión atrasada de la puerta funciona; ninguna, no.
   ══════════════════════════════════════════════════════════════════ */
"use strict";

/* Subir esto cuando cambie la lista de abajo. Cambiar el nombre es lo
   que borra el cache anterior: sin eso, un shell viejo puede sobrevivir
   a un despliegue y nadie entiende por qué el portero ve otra cosa. */
const CACHE = "puerta-v5";

const SHELL = [
  "./",
  "./index.html",
  "./admin.css?v=33",
  "./admin.js?v=34",
  "./puerta.js?v=32",
  "./csv.js?v=30",
  "../config.js",
  "../ticket.js?v=16",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js",
  "https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js",
  "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.min.js",
];

/* Los CDN están pinneados a una versión exacta, así que lo guardado no
   se pone viejo nunca: se sirve del cache y no se vuelve a pedir. Los
   archivos nuestros van por red primero, para que un despliegue llegue. */
const INMUTABLE = /^https:\/\/(cdn\.jsdelivr\.net|fonts\.gstatic\.com|fonts\.googleapis\.com)\//;

self.addEventListener("install", ev => {
  /* addAll falla entero si UN pedido falla, y con eso el portero se
     queda sin nada guardado por un CDN lento. De a uno: lo que entra,
     entra. */
  ev.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await Promise.all(SHELL.map(u =>
      cache.add(new Request(u, { cache: "reload" })).catch(() => {})));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", ev => {
  ev.waitUntil((async () => {
    const viejos = (await caches.keys()).filter(k => k !== CACHE && k.startsWith("puerta-"));
    await Promise.all(viejos.map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", ev => {
  const req = ev.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  if (url.hostname.endsWith(".supabase.co")) return;   // la base nunca

  if (INMUTABLE.test(req.url)) { ev.respondWith(cacheAntes(req)); return; }
  if (url.origin === self.location.origin) { ev.respondWith(redAntes(req)); return; }
});

async function cacheAntes(req) {
  const cache = await caches.open(CACHE);
  const hit = await cache.match(req);
  if (hit) return hit;
  try {
    const res = await fetch(req);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    /* Una fuente que no llega no puede tumbar la pantalla: el navegador
       usa la de sistema y la puerta sigue funcionando. */
    return new Response("", { status: 504, statusText: "sin conexión" });
  }
}

async function redAntes(req) {
  const cache = await caches.open(CACHE);
  try {
    const res = await fetch(req);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    return (await cache.match(req))
        || (await cache.match(req, { ignoreSearch: true }))
        || (req.mode === "navigate" ? await cache.match("./index.html") : undefined)
        || new Response("Sin conexión y sin copia guardada.",
                        { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } });
  }
}
