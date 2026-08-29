/* Datos del evento para MODO 'demo'. En modo 'supabase' esto no se usa: el
   evento, sus tipos y su fase vigente salen de la base. Se mantiene al día
   con supabase/seed.sql, para que el modo demo muestre el mismo evento que
   producción y no una versión vieja de él. */
window.DATOS_DEMO = {
  organizador: { nombre: "Amstel", fee_pct: 0.08, fee_fijo: 0, fee_piso: 0 },
  evento: {
    id: "e0000000-0000-4000-8000-000000000001",
    marca_1: "RED", marca_2: "CIRCLE",
    lugar: "Fexpo '26 · Santa Cruz de la Sierra",
    fecha_txt: "SÁB 12 SEP · 21:00",
    bajada: "La noche de Amstel en la Fexpo. Elegí tu entrada, pagá con QR y te la llevás al toque.",
    datos: [["Puertas","21:00"],["Edad mínima","18"],["Pago","Con QR"]],
    tope_entradas_orden: 10
  },
  fase: { nombre: "Preventa", hasta_txt: "hasta el 12 de septiembre" },
  tipos: [
    { id:"gen", nombre:"General", precio:120, antes:null, cupo:400,
      manillas:1, categoria:"entrada",
      desc:"Acceso al predio durante la noche.", incluye:null },
    { id:"vip", nombre:"VIP", precio:250, antes:null, cupo:60,
      manillas:1, categoria:"entrada",
      desc:"Sector elevado, con barra propia.",
      incluye:"Dos Amstel de bienvenida." },
  ],
};
