/* orden — la página a la que llega el link del correo.
   El uuid de la orden ES la credencial: es impredecible y solo lo tiene quien
   compró. Por eso esto NO es una vista con RLS sino una función: una vista
   puede perder `security_invoker` en un `create or replace` y quedar
   exponiendo todas las compras del sistema. Una función no falla así.
   Devuelve una sola orden y nada del resto. */
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const u = new URL(req.url);
    let id = u.searchParams.get("id");
    if (req.method === "POST") id = (await req.json().catch(() => ({}))).orden ?? id;
    if (!id || !/^[0-9a-f-]{36}$/i.test(id))
      return json({ ok: false, motivo: "Falta la orden." }, 400);

    const o = await uno(`ordenes?id=eq.${id}&select=id,estado,total,subtotal,fee,pago_ref,comprador_nombre,comprador_email,created_at,evento_id,organizador_id`);
    if (!o) return json({ ok: false, motivo: "No encontramos esa compra." }, 404);
    if (o.estado !== "pagada")
      return json({ ok: true, estado: o.estado, motivo: "Esta compra todavía no está pagada." });

    const e = await uno(`eventos?id=eq.${o.evento_id}&select=id,nombre,lugar,fecha,hora_inicio`);
    const ent = await rest(`entradas?orden_id=eq.${id}&select=code,precio,estado,used_at,fase_id,tipo_entrada(nombre),mesas(etiqueta,categoria)&order=created_at`);
    const fase = ent?.[0]?.fase_id
      ? await uno(`evento_fase?id=eq.${ent[0].fase_id}&select=nombre`) : null;

    const MES = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
    const DIA = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
    const f = new Date(e.fecha + "T00:00:00-04:00");
    const partes = String(e.nombre).split(" ");

    return json({
      ok: true, estado: "pagada",
      orden: { id: o.id, total: Number(o.total), subtotal: Number(o.subtotal),
               fee: Number(o.fee), pago_ref: o.pago_ref,
               comprador: o.comprador_nombre, email: o.comprador_email },
      evento: {
        id: e.id, marca_1: partes[0], marca_2: partes.slice(1).join(" "),
        lugar: e.lugar ?? "",
        fecha_txt: `${DIA[f.getDay()]} ${f.getDate()} ${MES[f.getMonth()]} · ${String(e.hora_inicio).slice(0,5)}`,
      },
      fase: { nombre: fase?.nombre ?? "" },
      entradas: (ent ?? []).map((x) => ({
        code: x.code, cliente: o.comprador_nombre, estado: x.estado, used_at: x.used_at,
        etiqueta: x.tipo_entrada?.nombre
          ?? ((x.mesas?.categoria === "lounge" ? "Lounge " : "Mesa ") + (x.mesas?.etiqueta ?? "")),
      })),
    });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
