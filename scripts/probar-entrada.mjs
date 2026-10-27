#!/usr/bin/env node
/* Prueba la entrada del correo (app/api/entrada.js) ya desplegada, sin
   mandar ningún correo: firma un pedido como lo firma enviar-entradas y
   guarda la imagen que vuelve.

     node scripts/probar-entrada.mjs ~/.ticketera-entrada.env
     node scripts/probar-entrada.mjs ~/.ticketera-entrada.env https://<vista-previa>.vercel.app/api/entrada

   El archivo es el mismo que se le pasa a scripts/secretos.py
   (`ENTRADA_FIRMA=…`): el secreto nunca va por argumento, que el argv lo
   lee cualquier proceso de la máquina. Ese archivo, con ENTRADA_FIRMA sola,
   es el que después carga secretos.py: no le agregues otras claves, que
   secretos.py sube todo lo que encuentra. Si la URL es una vista previa con
   Deployment Protection, el token de bypass va por el entorno:
   VERCEL_BYPASS="$(cat ~/.vercel-bypass)" node scripts/probar-entrada.mjs …
   (Settings → Deployment Protection → Protection Bypass for Automation).

   Dibuja una entrada de mentira (código PRUEBA…, que la puerta no conoce)
   sobre el arte real de LÜMEN, y además prueba que sin firma responda 401:
   si eso no pasa, cualquiera puede imprimir entradas con nuestro diseño. */
import fs from "node:fs";
import crypto from "node:crypto";

const [archivo, url = "https://ticketazo.com.bo/api/entrada"] = process.argv.slice(2);
if (!archivo) { console.error("Uso: node scripts/probar-entrada.mjs <archivo con ENTRADA_FIRMA=…> [url]"); process.exit(2); }
const env = Object.fromEntries(fs.readFileSync(archivo, "utf8").split("\n")
  .map((l) => l.trim()).filter((l) => l && !l.startsWith("#") && l.includes("="))
  .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, "")]; }));
if (!env.ENTRADA_FIRMA) { console.error(`${archivo} no tiene ENTRADA_FIRMA`); process.exit(2); }

const cuerpo = JSON.stringify({
  t: { code: "PRUEBA" + crypto.randomBytes(3).toString("hex").toUpperCase(), cliente: "Prueba Ñandú", etiqueta: "General" },
  evento: { id: "601921f2-6d02-4cb2-865a-40bd08897a38", marca_1: "Halloween", marca_2: "Ritual",
            lugar: "Santa Cruz de la Sierra", fecha_txt: "SÁB 31 OCT · 22:00",
            arte_url: "https://mjotxzcddhqqpuhkcetl.supabase.co/storage/v1/object/public/arte/lumen/halloween-ritual/evento.jpg",
            entrada_puerta: false },
  fase: { nombre: "Prueba", arte_url: null, sello: null },
  tope: 0,
});
const bypass = process.env.VERCEL_BYPASS;
const extra = bypass ? { "x-vercel-protection-bypass": bypass } : {};
const pedir = (h) => fetch(url, { method: "POST", headers: { "Content-Type": "application/json", ...extra, ...h }, body: cuerpo });

const sin = await pedir({});
console.log(`sin firma: ${sin.status} ${sin.status === 401 ? "(bien)" : "(MAL: tiene que ser 401)"}`);

const ts = String(Math.floor(Date.now() / 1000));
const firma = crypto.createHmac("sha256", env.ENTRADA_FIRMA).update(`${ts}.${cuerpo}`).digest("hex");
const t0 = Date.now();
const r = await pedir({ "x-ts": ts, "x-firma": firma });
const ms = Date.now() - t0;
if (!r.ok) { console.error(`con firma: ${r.status} ${await r.text()}`); process.exit(1); }
const buf = Buffer.from(await r.arrayBuffer());
const salida = `entrada-prueba.${r.headers.get("content-type") === "image/png" ? "png" : "jpg"}`;
fs.writeFileSync(salida, buf);
console.log(`con firma: ${r.status} en ${ms} ms · ${r.headers.get("content-type")} · ` +
  `${r.headers.get("x-entrada-ancho")}x${r.headers.get("x-entrada-alto")} · ${Math.round(buf.length / 1024)} KB · ` +
  `variante ${r.headers.get("x-entrada-variante")} (tiene que ser "arte") → ${salida}`);
