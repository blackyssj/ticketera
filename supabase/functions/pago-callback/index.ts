/* pago-callback — el liquidador nos avisa en qué terminó un pago.

   Sin esto, un pago al organizador queda en "En camino" para siempre: la
   función `liquidar` lo manda y nadie vuelve a contar el final. El
   organizador pregunta si le llegó y la única respuesta es entrar al portal
   de BeePay a mirar a mano, que es exactamente lo que este panel vino a
   evitar.

   ── quién puede llamar acá ──
   No hay JWT: el liquidador es un servidor Java que no tiene sesión de
   Supabase. La puerta es una cabecera compartida (`x-ticketazo`) cuyo valor
   vive en el secret CALLBACK_CLAVE de este lado y en `callback_auth_value`
   del otro. Se compara en tiempo constante para no filtrar el largo del
   secreto a fuerza de medir respuestas.

   Sin la clave configurada la función NO se abre: contesta 503. Un webhook
   que acepta a cualquiera puede marcar pagos como hechos, y eso no puede
   depender de que alguien se acuerde de cargar un secret.

   ── qué se hace con lo que llega ──
   Sólo se traduce el estado y se anota. El monto, el banco y el destino NO
   se tocan: son nuestros, quedaron congelados cuando se pidió el pago, y un
   webhook no es lugar para reescribirlos. Lo único que el otro lado sabe
   mejor que nosotros es en qué terminó.                                  */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-ticketazo",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const SB  = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };
const CLAVE = Deno.env.get("CALLBACK_CLAVE") ?? "";

/* Comparación en tiempo constante. Un `===` sobre strings corta en el primer
   carácter distinto, y esa diferencia de microsegundos, repetida, deja
   adivinar el secreto de a un carácter. Con XOR sobre todo el largo, todas
   las comparaciones tardan lo mismo. */
function igual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/* Los ocho estados del liquidador, traducidos a los cinco nuestros. Lo que
   no reconocemos se toma como "en camino": inventar un final —sobre todo
   'pagado'— a partir de un estado que no entendemos es la peor salida. */
function traducir(estado: string): string {
  switch (String(estado || "").toUpperCase()) {
    case "LIQUIDATED":              return "pagado";
    case "PENDING_BATCH_APPROVAL":  return "aprobacion_manual";
    case "ERROR":
    case "REVERSED":                return "rechazado";
    default:                        return "enviado";   // CREATED, RESERVED, PROCESSING, AUTHORIZED_PENDING_SETTLEMENT
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);

  if (!CLAVE) {
    console.error("pago-callback: falta CALLBACK_CLAVE, no atiendo a nadie");
    return json({ ok: false, motivo: "No configurado." }, 503);
  }
  if (!igual(req.headers.get("x-ticketazo") ?? "", CLAVE)) {
    console.warn("pago-callback: rechazado, cabecera incorrecta");
    return json({ ok: false, motivo: "No autorizado." }, 401);
  }

  try {
    const b = await req.json();
    /* `clientRequestId` es el id de nuestra fila en pago_organizador: se lo
       mandamos nosotros al pedir el pago, justamente para poder reconocerlo
       acá sin depender de ningún identificador del otro lado. */
    const pago = String(b?.clientRequestId ?? "").trim();
    if (!pago) return json({ ok: false, motivo: "Falta clientRequestId." }, 400);

    const estado = traducir(b?.status);
    const r = await fetch(`${SB}/rest/v1/rpc/confirmar_pago_organizador`, {
      method: "POST", headers: H,
      body: JSON.stringify({
        p_pago: pago,
        p_estado: estado,
        p_referencia: String(b?.txId ?? b?.payoutCode ?? ""),
        p_respuesta: b ?? {},
        p_motivo: b?.message ?? null,
      }),
    });
    const j = await r.json().catch(() => null);

    /* Un pago que no existe de este lado se contesta 200 igual. Si
       devolviéramos error, el liquidador reintentaría para siempre por algo
       que nunca vamos a poder resolver; el aviso queda en el log, que es
       donde sirve. */
    if (!j?.ok) {
      console.error(`pago-callback: ${pago} no se pudo anotar — ${JSON.stringify(j)}`);
      return json({ ok: true, anotado: false });
    }
    console.log(`pago-callback: ${pago} → ${estado}`);
    return json({ ok: true, anotado: true, estado });
  } catch (err) {
    console.error(`pago-callback falló: ${String((err as Error).message ?? err)}`);
    return json({ ok: false, motivo: "Error procesando el aviso." }, 500);
  }
});
