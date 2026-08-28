/* estado-orden — el camino que confirma y emite.
   Tres caminos llegan a emitir (este, el callback de la pasarela y el
   barrido) y ninguno confía en el otro. Este NUNCA cree lo que le manden:
   le pregunta a la pasarela y compara el monto contra ordenes.total antes de
   emitir. emitir_orden() es idempotente, así que repetirlo no duplica nada. */
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
// puesta, cualquiera se llevaba QR válidos sin pagar nada.
const PASARELA = (Deno.env.get("PASARELA") ?? "").trim().toLowerCase();
const V2PRO    = Deno.env.get("V2PRO_URL") ?? "https://pay.scrum-technology.com/api/v2pro";

/* Le pregunta a la pasarela, no al navegador. Devuelve el monto cobrado para
   que emitir_orden() lo compare: emitir por un monto distinto al cobrado no
   se deshace, porque la persona ya entró al evento. */
async function consultar(pago_ref: string): Promise<{ pagado: boolean; monto: number | null }> {
  if (PASARELA !== "v2pro") return { pagado: true, monto: null };
  const r = await fetch(`${V2PRO}/consulta_transaccion_v2.php`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      id_comercio: Deno.env.get("V2PRO_LLAVE"),
      usuario: Deno.env.get("V2PRO_USUARIO"),
      pass: Deno.env.get("V2PRO_PASS"),
      codigo: pago_ref,
    }),
  });
  const j = await r.json().catch(() => ({}));
  const fila = Array.isArray(j) ? j[0] : (j.data?.[0] ?? j);
  const estado = String(fila?.so_estado ?? "").toLowerCase();
  return {
    pagado: ["pagado", "aprobado", "completado", "1"].includes(estado),
    monto: fila?.so_monto != null ? Number(fila.so_monto) : null,
  };
}

/* Dispara el correo sin bloquear la respuesta. Si el runtime ofrece
   waitUntil lo usa; si no, la deja correr suelta. En los dos casos el
   comprador ya vio sus entradas en pantalla: el correo es el respaldo,
   no el camino principal. */
function avisarPorCorreo(orden: string) {
  const tarea = fetch(`${SB}/functions/v1/enviar-entradas`, {
    method: "POST", headers: H, body: JSON.stringify({ orden }),
  }).then(async (r) => {
    if (!r.ok) console.error(`enviar-entradas devolvió ${r.status} para ${orden}`);
  }).catch((e) => console.error(`enviar-entradas falló para ${orden}: ${e}`));

  const rt = (globalThis as any).EdgeRuntime;
  if (rt && typeof rt.waitUntil === "function") rt.waitUntil(tarea);
}

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

    const o = await uno(`ordenes?id=eq.${orden}&select=id,estado,total,pago_ref,comprador_nombre`);
    if (!o) return json({ ok: false, motivo: "Esa orden no existe." }, 404);

    if (o.estado === "pendiente" && o.pago_ref) {
      const { pagado, monto } = await consultar(o.pago_ref);
      if (pagado) {
        const r = await rpc("emitir_orden",
          { p_orden: o.id, p_monto_cobrado: monto, p_pago_ref: o.pago_ref });
        if (r && r.ok === false && r.motivo === "MONTO") {
          return json({ ok: false, estado: "revision_manual",
            motivo: "El monto cobrado no coincide con la compra. Lo estamos revisando." }, 409);
        }
        if (r && r.ok === false && r.motivo === "VENCIDA") {
          return json({ ok: false, estado: "vencida",
            motivo: "Se venció tu reserva antes de confirmarse el pago. Volvé a elegir." }, 409);
        }
        // Recién emitida: mandar el correo. Nunca esperar a que salga ni
        // dejar que su fallo tumbe una venta ya cobrada.
        if (r && r.ok === true && r.repetida === false) avisarPorCorreo(o.id);
      }
    }

    const f = await uno(`ordenes?id=eq.${orden}&select=estado`);
    if (f?.estado !== "pagada") return json({ ok: true, estado: f?.estado ?? "pendiente" });

    const ent = await rest(`entradas?orden_id=eq.${orden}&select=code,precio,tipo_entrada(nombre),mesas(etiqueta,categoria)&order=created_at`);
    // simulada=true deja explícito en la respuesta (y logueado abajo) que esta
    // confirmación no pasó por un cobro real, para que nunca se confunda con
    // uno. No se puede confiar en que el frontend lo muestre: por eso también
    // queda en el log de la función.
    const simulada = PASARELA !== "v2pro";
    if (simulada) console.log(`confirmación simulada (no se cobró nada): orden=${orden}`);
    return json({
      ok: true, estado: "pagada", simulada,
      entradas: (ent ?? []).map((e) => ({
        code: e.code, precio: Number(e.precio), cliente: o.comprador_nombre,
        etiqueta: e.tipo_entrada?.nombre
          ?? ((e.mesas?.categoria === "lounge" ? "Lounge " : "Mesa ") + (e.mesas?.etiqueta ?? "")),
      })),
    });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
