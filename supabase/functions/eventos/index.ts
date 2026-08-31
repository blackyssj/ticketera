/* eventos — la cartelera de TICKETAZO: qué hay a la venta, para cualquiera.

   Misma forma que `evento` y por las mismas razones: nada de imports
   remotos (la Management API no bundlea y un `jsr:` deja la función en
   BOOT_ERROR), se habla PostgREST con `fetch` pelado, y corre con
   service_role porque `anon` no tiene ni un permiso en esta base.

   Que corra con service_role la convierte en el guardián, así que la lista
   de campos de acá abajo es la definición de "lo que el público puede ver".
   No sale una recaudación, ni un cupo, ni un comprador, ni el uuid del
   evento: la portada no los necesita y lo que no viaja no se filtra. */
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
const rpc = (fn: string, args: Record<string, unknown>) =>
  rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

const MES = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];

/* La fecha se lee al mediodía UTC y con los getters UTC. `evento` la lee con
   offset -04:00 y getters locales, que da lo mismo mientras el runtime esté
   en UTC; acá no se depende de eso, porque una zona al oeste de La Paz
   correría el día uno para atrás y la portada mostraría el sábado como
   viernes. Un cartel con el día equivocado es peor que no tener cartel. */
function partesFecha(fecha: string) {
  const f = new Date(`${fecha}T12:00:00Z`);
  return { dia_semana: DIA[f.getUTCDay()], dia: String(f.getUTCDate()), mes: MES[f.getUTCMonth()] };
}

/* Hoy en La Paz (UTC-4, sin horario de verano). Un evento que ya pasó sale de
   la cartelera al día siguiente, no a la medianoche UTC — que en Bolivia son
   las 20:00 y todavía hay gente comprando en la puerta. */
const hoyEnLaPaz = () => new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10);

/* "Quedan pocas" con dos condiciones, no con una. Solo el porcentaje miente
   en los dos extremos: el 10% de un evento de 5.000 son 500 entradas y eso
   no es una urgencia, y el 10% de uno de 30 es 3 cuando todavía queda mesa.
   Se avisa cuando queda poco EN SERIO: menos del 10% y menos de 40 unidades.
   El aviso que se usa siempre deja de significar algo. */
const POCAS_PCT = 0.10;
const POCAS_ABS = 40;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const hoy = hoyEnLaPaz();

    /* Un organizador dado de baja se lleva sus eventos con él: `activo` es
       la llave que apaga un cliente entero sin tocarle los eventos uno por
       uno. El embebido filtra por el padre — de ahí el `!inner`. */
    const eventos = await rest(
      `eventos?estado=eq.publicado&fecha=gte.${hoy}` +
      `&select=id,slug,nombre,lugar,fecha,hora_inicio,flyer_url,organizadores!inner(slug,nombre)` +
      `&organizadores.activo=is.true` +
      `&order=fecha.asc,hora_inicio.asc`);

    /* En paralelo: la portada es lo primero que ve alguien que llega de
       WhatsApp, y encadenar una fase y sus precios por evento la vuelve
       lineal en la cantidad de eventos. */
    const cartelera = await Promise.all((eventos ?? []).map(async (e: any) => {
      /* La misma fase que usa `evento`, y por la misma función: si acá se
         reescribiera el "cuál está abierta", la portada podría anunciar un
         precio que la página de compra no reconoce. */
      const faseId = await rpc("fase_vigente", { p_evento: e.id });
      if (!faseId) return null;   // publicado pero sin venta abierta: no es cartelera

      const precios = await rest(
        `fase_precio?fase_id=eq.${faseId}&select=precio,cupo,tipo_id,tipo_entrada(activo,en_cartelera)`);

      /* Dos filtros y no uno. `activo` es el que decide si el producto se
         vende; `en_cartelera` es el que decide si CUENTA para lo que la
         portada dice del evento. La «Prueba de cobro» de Bs 1 está activa a
         propósito —es lo que verifica la pasarela por el mismo camino que
         usa un comprador— y por eso la tarjeta anunciaba "desde 1 Bs": un
         instrumento de prueba fijando el precio de la fiesta. Tampoco entra
         en la cuenta de cupo: tres unidades de prueba no pueden inclinar un
         evento a "últimas entradas" ni taparle el "agotado". */
      const vivos = (precios ?? []).filter(
        (p: any) => p.tipo_entrada?.activo && p.tipo_entrada?.en_cartelera !== false);
      const disp = await Promise.all(vivos.map((p: any) =>
        p.cupo === null ? Promise.resolve(null)     // sin tope: corta por fecha, no por stock
                        : rpc("disponibilidad_tipo", { p_fase: faseId, p_tipo: p.tipo_id })
                            .then((d) => Number(d ?? 0))));

      /* El "desde" es el más barato QUE SE PUEDE COMPRAR AHORA. Anunciar
         120 Bs cuando la General está agotada y lo único que queda es la VIP
         de 250 es la clase de precio que hace que el comprador se sienta
         estafado justo cuando iba a pagar. */
      let desde: number | null = null;
      let cupoTotal = 0, dispTotal = 0, hayCupo = false;
      vivos.forEach((p: any, i: number) => {
        const d = disp[i];
        if (d !== null) { hayCupo = true; cupoTotal += Number(p.cupo); dispTotal += d; }
        if (d === null || d > 0) {
          const v = Number(p.precio);
          if (desde === null || v < desde) desde = v;
        }
      });

      const venta = desde === null ? "agotado"
        : (hayCupo && dispTotal <= POCAS_ABS && dispTotal <= cupoTotal * POCAS_PCT) ? "ultimas"
        : "abierta";

      const o = e.organizadores;
      const p = partesFecha(e.fecha);
      const hora = String(e.hora_inicio).slice(0, 5);
      return {
        organizador: o.slug,
        organizador_nombre: o.nombre,
        slug: e.slug,
        nombre: e.nombre,
        // El link se arma acá para que la portada no tenga que saber cómo se
        // construye una ruta pública. El día que cambie, cambia en un lugar.
        url: `/${o.slug}/${e.slug}`,
        lugar: e.lugar ?? "",
        fecha: e.fecha,
        ...p,
        hora,
        fecha_txt: `${p.dia_semana} ${p.dia} ${p.mes} · ${hora}`,
        /* El flyer y NO `arte_url`: son dos imágenes con dos trabajos. El
           arte es el modelo sobre el que se dibuja la entrada —marca arriba,
           hueco al medio para el QR—, y recortado en una tarjeta lo que se
           luce es el hueco. Acá va el afiche que el organizador ya publicó
           en redes, que es por el que la gente reconoce el evento. Sin flyer
           viaja null y la portada dibuja un afiche tipográfico: no hay
           imagen de repuesto que valga la pena mostrar. */
        flyer_url: e.flyer_url ?? null,
        desde,
        venta,
      };
    }));

    return json({ ok: true, eventos: cartelera.filter(Boolean) });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
