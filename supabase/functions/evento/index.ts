/* evento — lo único que el público puede leer, y lo lee por acá.
   No hay vistas públicas ni grants a `anon`: una vista puede perder
   security_invoker en un `create or replace` y quedar leyendo sin RLS (así se
   filtró v_stats_rrpp en Puerta). Una función no falla de esa manera.
   Devuelve la misma forma que datos-demo.js para que el frontend no distinga
   el modo demo del real. */
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

// El frontend tiene que poder decirle al comprador que esto todavía no cobra.
// Si el dato no viaja, la página parece una venta real y no lo es.
// Normalizado igual que en iniciar-pago y estado-orden (recortado,
// minúsculas): acá no se falla cerrado porque este endpoint solo informa,
// no cobra ni emite — pero si el valor no es ninguno de los dos esperados,
// mejor mostrar la variable cruda que fingir "simulada" en silencio.
const PASARELA = (Deno.env.get("PASARELA") ?? "").trim().toLowerCase() || "(sin configurar)";

// Igual de fail-open que PASARELA antes de su arreglo: si no hay
// RESEND_API_KEY, enviar-entradas nunca manda nada, así que la pantalla
// final no puede prometer un correo que no va a salir. El frontend usa
// este dato para no prometerlo.
const CORREO_CONFIGURADO = !!Deno.env.get("RESEND_API_KEY");

const MES = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
const q = (s: string) => encodeURIComponent(s);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const u = new URL(req.url);
    let org = u.searchParams.get("organizador"), ev = u.searchParams.get("evento");
    if (req.method === "POST") {
      const b = await req.json().catch(() => ({}));
      org = b.organizador ?? org; ev = b.evento ?? ev;
    }
    if (!org || !ev) return json({ ok: false, motivo: "Falta organizador o evento." }, 400);

    const o = await uno(`organizadores?slug=eq.${q(org)}&activo=is.true&select=id,nombre,fee_pct,fee_fijo_transaccion,fee_piso`);
    if (!o) return json({ ok: false, motivo: "Ese organizador no existe." }, 404);

    const e = await uno(`eventos?organizador_id=eq.${o.id}&slug=eq.${q(ev)}&select=id,nombre,descripcion,lugar,fecha,hora_inicio,edad_min,estado,tope_entradas_orden,arte_url`);
    if (!e) return json({ ok: false, motivo: "Ese evento no existe." }, 404);
    if (e.estado !== "publicado") return json({ ok: false, motivo: "El evento todavía no está a la venta." }, 404);

    const faseId = await rpc("fase_vigente", { p_evento: e.id });
    if (!faseId) return json({ ok: false, motivo: "No hay ninguna fase de venta abierta." }, 409);

    const fase = await uno(`evento_fase?id=eq.${faseId}&select=nombre,hasta,arte_url`);
    const precios = await rest(`fase_precio?fase_id=eq.${faseId}&select=tipo_id,precio,cupo,tipo_entrada(id,nombre,descripcion,incluye,categoria,manillas,orden,activo)`);

    const tipos = [];
    for (const p of precios ?? []) {
      const t = p.tipo_entrada;
      if (!t?.activo) continue;
      const disp = await rpc("disponibilidad_tipo", { p_fase: faseId, p_tipo: p.tipo_id });
      tipos.push({ id: t.id, nombre: t.nombre, desc: t.descripcion ?? "",
                   incluye: t.incluye ?? null,
                   categoria: t.categoria ?? "entrada",
                   precio: Number(p.precio), antes: null,
                   cupo: p.cupo === null ? 9999 : Number(disp ?? 0),
                   manillas: t.manillas ?? 1, orden: t.orden });
    }
    tipos.sort((a, b) => a.orden - b.orden);

    // El comprador ya no elige mesa en un plano: compra el producto y el
    // relacionador le asigna cuál. El dato del hero sale del cupo que queda
    // de los productos de mesa, NO de cuántas filas hay en `mesas`: ahí
    // están todas las del predio, vendidas incluidas, y el hero prometía 24
    // disponibles con cero para vender.
    const reservas = tipos.filter((t) => t.categoria === "mesa")
                          .reduce((n, t) => n + (t.cupo === 9999 ? 0 : t.cupo), 0);

    // el público ve tres estados y ninguno lleva el nombre de nadie
    const f = new Date(e.fecha + "T00:00:00-04:00");
    // Orden deliberado: la planta baja primero. Derivarlo del orden de las
    // mesas lo dejaba alfabético (A1 antes que M1) y abría en la alta.


    const partes = String(e.nombre).split(" ");
    return json({
      ok: true,
      pasarela: PASARELA,
      correo_configurado: CORREO_CONFIGURADO,
      organizador: { nombre: o.nombre, fee_pct: Number(o.fee_pct),
                     fee_fijo: Number(o.fee_fijo_transaccion), fee_piso: Number(o.fee_piso) },
      evento: {
        id: e.id,
        marca_1: partes[0],
        marca_2: partes.slice(1).join(" "),
        lugar: e.lugar ?? "",
        // La fecha también cruda: el texto de abajo no trae año, y el front la
        // necesita entera para el .ics y para "Mis entradas". Sin esto el
        // cliente la reconstruye adivinando el año por el día de semana.
        fecha: e.fecha,
        hora_inicio: String(e.hora_inicio).slice(0,5),
        fecha_txt: `${DIA[f.getDay()]} ${f.getDate()} ${MES[f.getMonth()]} · ${String(e.hora_inicio).slice(0,5)}`,
        bajada: e.descripcion ?? "",
        // El dato de reservas solo aparece si hay reservas. "0 disponibles"
        // en un evento que no vende mesas no es un cero, es un renglón que
        // el comprador tiene que descartar solo.
        datos: [["Puertas", String(e.hora_inicio).slice(0,5)],
                ["Edad mínima", String(e.edad_min)],
                ...(reservas > 0 ? [["Reservas", `${reservas} disponibles`]] : []),
                ["Pago", "Con QR"]],
        tope_entradas_orden: e.tope_entradas_orden,
        arte_url: e.arte_url ?? null,
      },
      // `hasta` en crudo para que el front diga "cierra en 3 días" sólo
      // cuando hay un cierre de verdad; `hasta_txt` sigue para el chip.
      fase: { nombre: fase?.nombre ?? "", arte_url: fase?.arte_url ?? null, hasta: fase?.hasta ?? null, hasta_txt: fase?.hasta
        ? "hasta el " + new Date(fase.hasta).toLocaleDateString("es-BO",
            { day: "numeric", month: "long", timeZone: "America/La_Paz" })
        : "" },
      tipos,
    });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
