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
    const cuerpo = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    let id = cuerpo.orden ?? u.searchParams.get("id");
    const ref = cuerpo.pago_ref ?? u.searchParams.get("pago_ref");

    const CAMPOS = "id,estado,total,subtotal,fee,pago_ref,comprador_nombre," +
                   "comprador_email,created_at,evento_id,organizador_id";
    const esUuid = (v: unknown) => typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v);

    let o = null;
    if (esUuid(id)) {
      o = await uno(`ordenes?id=eq.${id}&select=${CAMPOS}`);
    } else if (ref) {
      /* La vuelta de la pasarela.
         Al redirigir, v2pro pega `?id=<id_transaccion>` a urlRespuesta: ese
         id es SUYO, no el uuid de la orden, así que la búsqueda por id no
         encuentra nada y hay que caer en pago_ref.

         Pero el uuid de la orden es la credencial de esta página —
         impredecible, solo lo tiene quien compró— y un id de transacción de
         una pasarela no promete nada de eso: puede ser corto o correlativo.
         Como acá se devuelven el nombre del comprador y los códigos de QR,
         una búsqueda libre por pago_ref sería una puerta para leer compras
         ajenas probando números.

         Por eso este camino se acota a lo que necesita: una compra reciente.
         La vuelta del pago pasa en minutos; 12 horas cubre hasta un banco
         lento y deja afuera todo el histórico. Lo que se puede tantear pasa
         de "todas las compras que existieron" a "las de hoy", y el que llega
         por acá es reenviado enseguida al link con el uuid, que es el que le
         queda guardado. */
      const desde = new Date(Date.now() - 12 * 60 * 60 * 1000).toISOString();
      if (String(ref).length < 6)
        return json({ ok: false, motivo: "No encontramos esa compra." }, 404);
      o = await uno(`ordenes?pago_ref=eq.${encodeURIComponent(String(ref))}` +
                    `&created_at=gte.${desde}&select=${CAMPOS}`);
    }

    if (!id && !ref) return json({ ok: false, motivo: "Falta la orden." }, 400);
    if (!o) return json({ ok: false, motivo: "No encontramos esa compra." }, 404);
    id = o.id;
    if (o.estado !== "pagada") {
      /* Devuelve el uuid: quien llegó por el pago_ref de la pasarela lo
         necesita para poder preguntar por estado-orden mientras el cobro se
         confirma, y para quedarse con el link bueno.

         Y el arte sobre el que se va a dibujar la entrada (el de la fase si
         tiene, si no el del evento, como ticket.js), para que la página lo
         baje MIENTRAS confirma el pago y no recién al final. Si esto falla
         no importa: es una precarga. */
      let arte_url: string | null = null;
      try {
        const [it, ev] = await Promise.all([
          uno(`orden_items?orden_id=eq.${o.id}&fase_id=not.is.null&select=evento_fase(arte_url)&limit=1`),
          uno(`eventos?id=eq.${o.evento_id}&select=arte_url`),
        ]);
        arte_url = it?.evento_fase?.arte_url ?? ev?.arte_url ?? null;
      } catch { /* sin precarga */ }
      return json({ ok: true, estado: o.estado, orden: o.id, arte_url,
                    motivo: "Esta compra todavía no está pagada." });
    }

    const e = await uno(`eventos?id=eq.${o.evento_id}&select=id,nombre,lugar,fecha,hora_inicio,arte_url`);
    const ent = await rest(`entradas?orden_id=eq.${id}&select=code,precio,estado,used_at,fase_id,tipo_entrada(nombre),mesas(etiqueta,categoria)&order=created_at`);
    /* Dos datos de 0104, aparte y con red: si fallan (la columna todavía no
       existe porque 0104 no se aplicó, o un corte), la página sale como
       siempre. Esta es la página donde el que pagó ve su QR la noche del
       evento: un detalle de cómo se dibuja no la puede tumbar.
         · espejo: la fecha viene de Plataforma Puerta → la entrada se dibuja
           igual que la de Puerta, y fase_online dice qué fase inventó el
           espejo (esa no lleva sello).
         · titulo_marca: el título es "BOWIE" y la noche va abajo. */
    const [fase, espejo, org] = await Promise.all([
      ent?.[0]?.fase_id
        ? uno(`evento_fase?id=eq.${ent[0].fase_id}&select=id,nombre,arte_url`) : Promise.resolve(null),
      uno(`puerta_evento?evento_id=eq.${e.id}&select=fase_online`).catch(() => null),
      uno(`organizadores?id=eq.${o.organizador_id}&select=nombre,titulo_marca`).catch(() => null),
    ]);

    const MES = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
    const DIA = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
    const f = new Date(e.fecha + "T00:00:00-04:00");
    const marca = org?.titulo_marca === true && !!org?.nombre;
    const partes = marca
      ? [String(org.nombre).toUpperCase(), String(e.nombre)]
      : String(e.nombre).split(" ");

    return json({
      ok: true, estado: "pagada",
      orden: { id: o.id, total: Number(o.total), subtotal: Number(o.subtotal),
               fee: Number(o.fee), pago_ref: o.pago_ref,
               comprador: o.comprador_nombre, email: o.comprador_email },
      evento: {
        id: e.id, marca_1: partes[0], marca_2: partes.slice(1).join(" "),
        lugar: e.lugar ?? "",
        // Cruda además del texto: "Mis entradas" ordena por fecha real.
        fecha: e.fecha,
        hora_inicio: String(e.hora_inicio).slice(0,5),
        fecha_txt: `${DIA[f.getDay()]} ${f.getDate()} ${MES[f.getMonth()]} · ${String(e.hora_inicio).slice(0,5)}`,
        arte_url: e.arte_url ?? null,
        titulo_marca: marca,
        entrada_puerta: !!espejo,
      },
      /* sello: lo que Puerta imprime en la entrada de una fase suya sin arte
         propio. La 'Online' del espejo no existe en Puerta: sin sello. */
      fase: { nombre: fase?.nombre ?? "", arte_url: fase?.arte_url ?? null,
              sello: espejo && fase?.id && fase.id !== espejo.fase_online ? fase.nombre : null },
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
