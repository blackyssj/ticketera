/* eventos — la cartelera de TICKETAZO: qué hay a la venta, para cualquiera.

   Misma forma que `evento` y por las mismas razones: nada de imports
   remotos (la Management API no bundlea y un `jsr:` deja la función en
   BOOT_ERROR), se habla PostgREST con `fetch` pelado, y corre con
   service_role porque `anon` no tiene ni un permiso en esta base.

   Que corra con service_role la convierte en el guardián, así que la lista
   de campos de acá abajo es la definición de "lo que el público puede ver".
   No sale una recaudación, ni un cupo, ni un comprador, ni el uuid del
   evento: la portada no los necesita y lo que no viaja no se filtra.

   Un solo viaje a la base: `cartelera_publica()` (migración 0048) trae
   los eventos a la venta con sus precios vivos y la disponibilidad ya
   contada. Antes eran tres pedidos en fila por evento (fase, precios,
   disponibilidad por tipo), y la portada es lo primero que ve alguien
   que llega de WhatsApp. La regla del "desde" y del estado de venta se
   quedó acá: la base cuenta, esta función decide. */
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
    /* Lo que decide qué evento entra vive en la base, en cartelera_publica():
       publicado, con fecha de hoy (La Paz) en adelante, organizador activo
       —`activo` es la llave que apaga un cliente entero sin tocarle los
       eventos uno por uno— y con una fase abierta por la MISMA
       fase_vigente() que usa `evento`: si acá se reescribiera el "cuál
       está abierta", la portada podría anunciar un precio que la página de
       compra no reconoce. Los tipos ya vienen filtrados por `activo` (se
       vende) y `en_cartelera` (cuenta para lo que la portada dice): la
       «Prueba de cobro» de Bs 1 está activa a propósito y no puede fijar
       el "desde" de la fiesta ni inclinar el cupo a "últimas". */
    const eventos = await rpc("cartelera_publica", {});

    const cartelera = (eventos ?? []).map((e: any) => {
      const vivos = e.precios ?? [];
      // sin tope (cupo null) corta por fecha, no por stock: queda null
      const disp = vivos.map((p: any) => p.cupo === null ? null : Number(p.disponible ?? 0));

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
    });

    return json({ ok: true, eventos: cartelera });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
