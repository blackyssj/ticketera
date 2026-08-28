/* iniciar-pago — arranca el cobro y guarda la referencia.
   Dos pasarelas: `v2pro` (BeePay, la real) y `simulada`. La elección la hace
   la variable PASARELA del servidor, nunca el cliente. El orden_id viaja en
   so_extra1, que ya existe libre en `solicitudpagos`: sin tabla puente. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

// service_role: estas funciones SON el guardián. La anon key no escribe nunca.
const SB  = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

async function rest(ruta: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${ruta}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(j?.message ?? j?.hint ?? t);
  return j;
}
const uno = async (ruta: string) => (await rest(ruta))?.[0] ?? null;
const rpc = (fn: string, args: Record<string, unknown>) =>
  rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

// Normalizado (recortado, minúsculas) para que "V2PRO" o " simulada " no
// caigan por afuera de las dos comparaciones exactas de abajo. Si no viene
// una de las dos, la función se niega a operar en vez de asumir cuál es:
// el default anterior (?? "simulada") era fail-open — sin la variable
// puesta, cualquiera cobraba en modo simulado sin que nadie lo supiera.
const PASARELA = (Deno.env.get("PASARELA") ?? "").trim().toLowerCase();
const V2PRO    = Deno.env.get("V2PRO_URL") ?? "https://pay.scrum-technology.com/api/v2pro";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);
  try {
    if (PASARELA !== "simulada" && PASARELA !== "v2pro") {
      console.error(`PASARELA mal configurada: "${Deno.env.get("PASARELA") ?? ""}"`);
      return json({ ok: false, motivo: "La pasarela no está configurada correctamente. Avisale al organizador." }, 500);
    }
    const { orden } = await req.json();
    if (!orden) return json({ ok: false, motivo: "Falta la orden." }, 400);

    const o = await uno(`ordenes?id=eq.${orden}&select=id,estado,total,expira_at,pago_ref,comprador_nombre,comprador_email,organizador_id`);
    if (!o) return json({ ok: false, motivo: "Esa orden no existe." }, 404);
    if (o.estado === "pagada") return json({ ok: true, pago_ref: o.pago_ref, ya_pagada: true });
    if (o.estado !== "pendiente") return json({ ok: false, motivo: "Esa compra ya no está vigente." }, 409);
    if (new Date(o.expira_at) < new Date())
      return json({ ok: false, motivo: "Se venció la reserva. Volvé a elegir." }, 409);
    if (o.pago_ref) return json({ ok: true, pago_ref: o.pago_ref, repetida: true });

    let pago_ref = "", url: string | null = null;

    if (PASARELA === "v2pro") {
      const llave = Deno.env.get("V2PRO_LLAVE");
      if (!llave) return json({ ok: false, motivo: "La pasarela no está configurada." }, 500);
      const r = await fetch(`${V2PRO}/solicitud_pago.php`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          id_comercio: llave, monto: Number(o.total), moneda: "BOB",
          nombreComprador: o.comprador_nombre, correoElectronico: o.comprador_email,
          descripcion: "Entradas", so_extra1: o.id,
        }),
      });
      const j = await r.json().catch(() => ({}));
      pago_ref = j.id_transaccion ?? j.transaccion ?? "";
      url = j.url ?? j.url_pago ?? null;
      if (!pago_ref) return json({ ok: false, motivo: "La pasarela no devolvió una transacción." }, 502);
    } else {
      // Simulada: no se cobra nada. Sirve para probar el flujo entero.
      pago_ref = "SIM-" + String(o.id).slice(0, 8).toUpperCase();
    }

    await rest(`ordenes?id=eq.${o.id}`, { method: "PATCH", body: JSON.stringify({ pago_ref }) });
    return json({ ok: true, pago_ref, url, simulada: PASARELA !== "v2pro" });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
