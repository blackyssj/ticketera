/* Sin imports a propósito: el runtime de Edge Functions no resuelve módulos
   remotos cuando se despliega por la API de gestión, así que se habla
   PostgREST por fetch. Menos dependencias y menos que romper.
   Este archivo es la referencia; su contenido va copiado en cada función. */
export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
