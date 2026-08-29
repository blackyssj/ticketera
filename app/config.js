// Configuración de TICKETAZO.
//
// MODO 'supabase' → base y funciones reales. Es el modo de producción.
// MODO 'demo'     → todo en memoria, sin backend. Sirve para mostrar la
//                   interfaz sin tocar datos ni cupos reales.
//
// La anon key es pública por diseño: sola no da acceso a nada. En esta base
// `anon` no tiene ni un permiso — no lee tablas, no escribe y no ejecuta
// funciones. Todo pasa por las Edge Functions, que corren con service_role
// del lado del servidor. La service_role NUNCA va acá.
// Acá NO va un organizador ni un evento por defecto. Los hubo mientras `/`
// servía la página de un solo evento; desde que `/` es la portada de
// TICKETAZO, el evento sale siempre del path (`/<organizador>/<evento>`,
// app.js). Un default acá volvería a ser una trampa: cualquier ruta rota
// dejaría de fallar y pasaría a vender el evento de otro cliente, en
// silencio y con la marca equivocada.
window.CONFIG = {
  MODO: "supabase",
  SUPABASE_URL: "https://mjotxzcddhqqpuhkcetl.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0"
};
