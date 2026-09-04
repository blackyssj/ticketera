/* barrer-pagos — le pregunta a la pasarela por las órdenes que quedaron
   esperando, y emite las que ya se cobraron.

   Existe porque la emisión NO puede depender de que el navegador del
   comprador vuelva de la pasarela. Pasó de verdad: se cobró Bs 1, la
   pasarela mostró "operación realizada con éxito" y no redirigió. La orden
   quedó pendiente y la persona sin su entrada.

   La llama pg_cron cada minuto (migración 0041). No la llama nadie más:
   pide el mismo secreto que se le configuró al cron. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-barrido",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

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
const rpc = (fn: string, args: Record<string, unknown>) =>
  rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

const PASARELA = (Deno.env.get("PASARELA") ?? "").trim().toLowerCase();
const V2PRO    = Deno.env.get("V2PRO_URL") ?? "https://pay.scrum-technology.com/api/v2pro";
/* El mismo secreto que lleva el cron. Sin esto la función queda abierta a
   cualquiera con la anon key: no emite nada que no esté pagado, pero deja
   a un desconocido disparar consultas contra el comercio a discreción. */
const CLAVE = Deno.env.get("BARRIDO_CLAVE") ?? "";

/* La consulta, con los nombres que la API pide de verdad: el parámetro es
   `id_transaccion` (no `codigo`) y el estado viene en datos.estado (no
   so_estado). Con los otros nombres contesta {"error":"1009"} y la orden
   se queda pendiente para siempre con la plata cobrada. */
async function consultar(pago_ref: string) {
  const usuario = Deno.env.get("V2PRO_USUARIO") ?? "";
  const pass    = Deno.env.get("V2PRO_PASS") ?? "";
  const r = await fetch(`${V2PRO}/consulta_transaccion_v2.php`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(usuario && pass ? { "Authorization": "Basic " + btoa(`${usuario}:${pass}`) } : {}),
    },
    body: JSON.stringify({ id_comercio: Deno.env.get("V2PRO_LLAVE"), id_transaccion: pago_ref }),
  });
  const crudo = await r.text();
  const j = (() => { try { return JSON.parse(crudo); } catch { return {}; } })();
  if (String(j?.error ?? "0") !== "0") {
    console.error(`consulta rechazada (${pago_ref.slice(0, 40)}…): ${crudo.slice(0, 200)}`);
    return { pagado: false, monto: null as number | null };
  }
  const d = j?.datos;
  const fila = Array.isArray(d) ? (d[0] ?? {}) : (d ?? {});
  const estado = String(fila.estado ?? "").trim().toLowerCase();
  const monto = fila.monto;
  return {
    pagado: ["pagado", "aprobado", "completado", "1"].includes(estado),
    monto: monto != null && monto !== "" ? Number(monto) : null,
  };
}

/* El correo importa más acá que en estado-orden. Si el barrido está emitiendo
   esta orden es porque el navegador del comprador nunca volvió de la pasarela
   —el caso que hizo existir esta función—, así que nadie le mostró sus
   entradas en pantalla: el correo es lo único que le queda. Un fallo suyo no
   puede tumbar una emisión ya hecha, por eso solo se registra. */
function avisarPorCorreo(orden: string) {
  return fetch(`${SB}/functions/v1/enviar-entradas`, {
    method: "POST", headers: H, body: JSON.stringify({ orden }),
  }).then(async (r) => {
    if (!r.ok) console.error(`barrido: enviar-entradas devolvió ${r.status} para ${orden}`);
  }).catch((e) => console.error(`barrido: enviar-entradas falló para ${orden}: ${e}`));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);
  if (!CLAVE || req.headers.get("x-barrido") !== CLAVE)
    return json({ ok: false, motivo: "No." }, 403);
  if (PASARELA !== "v2pro") return json({ ok: true, salteado: "pasarela simulada", revisadas: 0 });

  try {
    const pendientes: Array<{ id: string; pago_ref: string }> =
      await rpc("pagos_a_confirmar", { p_limite: 20 });
    let emitidas = 0, revision = 0;
    const correos: Promise<void>[] = [];

    for (const o of pendientes ?? []) {
      const { pagado, monto } = await consultar(o.pago_ref);
      if (!pagado) continue;
      /* emitir_orden compara el monto cobrado contra el total y, si no
         coincide, manda la orden a revisión manual en vez de emitir.
         Se le pasa el monto a propósito: emitir por una cifra distinta a
         la que se cobró no se deshace, porque la persona ya entró. */
      const r = await rpc("emitir_orden",
        { p_orden: o.id, p_monto_cobrado: monto, p_pago_ref: o.pago_ref });
      const res = Array.isArray(r) ? r[0] : r;
      if (res?.ok) {
        emitidas++;
        console.log(`barrido: emitida ${o.id}`);
        // Solo la emisión nueva manda correo: emitir_orden es idempotente y
        // devuelve repetida=true si la orden ya estaba emitida. Sin este
        // guarda, una orden que el barrido vuelva a mirar le manda el mismo
        // correo al comprador otra vez.
        if (res.repetida === false) correos.push(avisarPorCorreo(o.id));
      }
      else { revision++; console.error(`barrido: ${o.id} no se emitió — ${res?.motivo}`); }
    }

    /* Los correos no bloquean la emisión, pero sí tienen que sobrevivir al
       return: si el isolate se apaga con los fetch a medio salir, la orden
       queda emitida y el comprador sin aviso, que es el agujero que esta
       función vino a tapar. Con waitUntil siguen después de responder; sin
       él se esperan acá, que para un cron de veinte órdenes no es caro. */
    const rt = (globalThis as any).EdgeRuntime;
    if (rt && typeof rt.waitUntil === "function") rt.waitUntil(Promise.all(correos));
    else await Promise.all(correos);

    return json({ ok: true, revisadas: (pendientes ?? []).length, emitidas, revision,
                  correos: correos.length });
  } catch (err) {
    console.error(`barrido falló: ${String((err as Error).message ?? err)}`);
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
