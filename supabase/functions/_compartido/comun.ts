/* Prólogo compartido por las cuatro Edge Functions.
 *
 * NO se importa: el runtime de Supabase no bundlea las funciones cuando se
 * despliegan por la API de gestión, así que cualquier `import` remoto —`jsr:`
 * o `https://esm.sh/...`— hace que la función arranque con BOOT_ERROR. Por eso
 * este bloque va COPIADO dentro de cada `index.ts`, y por eso hablamos
 * PostgREST con `fetch` en vez de usar @supabase/supabase-js.
 *
 * Si cambia algo de acá, hay que copiarlo en las cuatro y redesplegarlas:
 *   python3 scripts/desplegar-funciones.py
 */
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
