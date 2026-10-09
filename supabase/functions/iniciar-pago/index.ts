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

/* A dónde vuelve el comprador cuando termina de pagar. Va sin query string
   a propósito: la pasarela le pega `?id=<id_transaccion>` al redirigir, y si
   la URL ya trajera un `?`, el segundo llega como `&` mal formado o pisa al
   primero según cómo lo arme cada pasarela. */
const SITIO = (Deno.env.get("SITIO_URL") ?? "https://ticketera-coral.vercel.app")
  .replace(/\/+$/, "");

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

    const o = await uno(`ordenes?id=eq.${orden}&select=id,estado,total,expira_at,pago_ref,pago_url,comprador_nombre,comprador_email,organizador_id`);
    if (!o) return json({ ok: false, motivo: "Esa orden no existe." }, 404);
    if (o.estado === "pagada") return json({ ok: true, pago_ref: o.pago_ref, ya_pagada: true });
    if (o.estado !== "pendiente") return json({ ok: false, motivo: "Esa compra ya no está vigente." }, 409);
    if (new Date(o.expira_at) < new Date())
      return json({ ok: false, motivo: "Se venció la reserva. Volvé a elegir." }, 409);
    /* El front reintenta con la misma orden (misma client_key) cuando se le
       cortó la respuesta. Si el cobro ya estaba iniciado se devuelve el link
       guardado (0101): v2pro lo da una sola vez. Sin link guardado (órdenes
       de antes de 0101) el front no muestra la simulada: pide otra orden. */
    if (o.pago_ref) return json({ ok: true, pago_ref: o.pago_ref, url: o.pago_url ?? null,
                                  simulada: PASARELA !== "v2pro", repetida: true });

    let pago_ref = "", url: string | null = null;

    if (PASARELA === "v2pro") {
      const llave = Deno.env.get("V2PRO_LLAVE");
      if (!llave) return json({ ok: false, motivo: "La pasarela no está configurada." }, 500);
      /* La API exige HTTP Basic. Sin ese header descarta el request entero
         y no contesta nada — no un 401 con motivo, nada: el `await r.json()`
         de abajo caía al catch y el error salía como "la pasarela no
         devolvió una transacción", que apunta al lugar equivocado. */
      const usuario = Deno.env.get("V2PRO_USUARIO");
      const pass    = Deno.env.get("V2PRO_PASS");
      if (!usuario || !pass)
        return json({ ok: false, motivo: "La pasarela no está configurada." }, 500);

      /* Con tope de 40 s, por debajo de los 45 s con los que el front corta
         y reintenta: así el primer intento no sigue vivo cuando llega el
         segundo sobre la misma orden. */
      let r: Response;
      try {
      r = await fetch(`${V2PRO}/solicitud_pago.php`, {
        method: "POST",
        signal: AbortSignal.timeout(40000),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Basic " + btoa(`${usuario}:${pass}`),
        },
        body: JSON.stringify({
          id_comercio: llave,
          monto: Number(o.total),
          moneda: "BOB",
          // El campo se llama `correo`, no `correoElectronico`: la API valida
          // el nombre exacto y contesta {"error":"1009"} si no está.
          correo: o.comprador_email,
          nombreComprador: o.comprador_nombre,
          descripcion: "Entradas",
          // Obligatorio: es con esto que la pasarela nombra a la orden.
          codigoTransaccion: o.id,
          urlRespuesta: `${SITIO}/orden/`,
          /* R, no W. W es checkout embebido en iframe: la pasarela cobra
             igual pero devuelve la URL de retorno vacía, así que el
             comprador paga bien y se queda parado en la página de ellos,
             sin entrada y sin saber qué pasó. Pasó de verdad con el primer
             cobro real. La pasarela solo devuelve el retorno con R o I. */
          modalidad: "R",
          so_extra1: o.id,
        }),
      });
      } catch (err) {
        console.error(`v2pro sin respuesta para ${o.id}: ${err}`);
        return json({ ok: false, motivo: "La pasarela está tardando demasiado. Probá de nuevo en un momento." }, 504);
      }
      const crudo = await r.text();
      const j = (() => { try { return JSON.parse(crudo); } catch { return {}; } })();
      pago_ref = j.id_transaccion ?? j.transaccion ?? "";
      url = j.url ?? j.url_pago ?? null;
      if (!pago_ref) {
        /* Al log del servidor, no a la respuesta: el cuerpo de la pasarela
           puede traer datos del comercio. Al comprador se le dice qué pasó
           sin hacerlo cargar con el detalle. */
        console.error(`v2pro rechazo la solicitud (HTTP ${r.status}): ${crudo.slice(0, 500)}`);
        return json({ ok: false, motivo: "La pasarela no devolvió una transacción." }, 502);
      }
    } else {
      // Simulada: no se cobra nada. Sirve para probar el flujo entero.
      pago_ref = "SIM-" + String(o.id).slice(0, 8).toUpperCase();
    }

    /* Sólo si nadie lo guardó antes. Con el reintento por la misma orden,
       dos intentos pueden pedir cobro a la vez; el que termina segundo no
       pisa al primero —el comprador pudo haber abierto ya ese QR—: devuelve
       lo guardado. v2pro deduplica por codigoTransaccion, así que en general
       son la misma transacción; si no, la otra queda huérfana y se loguea. */
    const guardada = await rest(`ordenes?id=eq.${o.id}&pago_ref=is.null`, {
      method: "PATCH", headers: { Prefer: "return=representation" },
      body: JSON.stringify({ pago_ref, pago_url: url }),
    });
    if (!guardada?.length) {
      const ya = await uno(`ordenes?id=eq.${o.id}&select=pago_ref,pago_url`);
      if (ya?.pago_ref !== pago_ref)
        console.error(`iniciar-pago: transacción huérfana ${pago_ref.slice(0, 40)}… para ${o.id}`);
      return json({ ok: true, pago_ref: ya?.pago_ref, url: ya?.pago_url ?? null,
                    simulada: PASARELA !== "v2pro", repetida: true });
    }
    return json({ ok: true, pago_ref, url, simulada: PASARELA !== "v2pro" });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
