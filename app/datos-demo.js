/* Datos del evento para MODO 'demo'. En modo 'supabase' esto no se usa: el
   evento, sus tipos y su fase vigente salen de la base. Se mantiene al día
   con supabase/seed.sql, para que el modo demo muestre el mismo evento que
   producción y no una versión vieja de él. */
window.DATOS_DEMO = {
  organizador: { nombre: "Amstel", fee_pct: 0.07, fee_fijo: 3, fee_piso: 5 },
  evento: {
    id: "e0000000-0000-4000-8000-000000000001",
    marca_1: "RED", marca_2: "CIRCLE",
    lugar: "Fexpo '26 · Santa Cruz de la Sierra",
    fecha_txt: "SÁB 12 SEP · 21:00",
    bajada: "Reservá tu mesa para las noches de Amstel en la Fexpo. Elegí el combo, pagá con QR y las manillas te llegan al correo.",
    datos: [["Puertas","21:00"],["Edad mínima","18"],["Reservas","74 disponibles"],["Pago","Con QR"]],
    tope_entradas_orden: 10
  },
  fase: { nombre: "Preventa", hasta_txt: "hasta el 12 de septiembre" },
  tipos: [
    { id:"sab-serenata", nombre:"Combo Sábados + Serenata", precio:8000, antes:null, cupo:10,
      manillas:10, categoria:"mesa",
      desc:"Tu mesa para los sábados y la noche de serenata.",
      incluye:"Bs 6.000 en consumo + 10 manillas, válidas los 3 días." },
    { id:"sab", nombre:"Combo Sábados", precio:5500, antes:null, cupo:14,
      manillas:10, categoria:"mesa",
      desc:"Tu mesa para los sábados de la Fexpo.",
      incluye:"Bs 4.000 en consumo + 10 manillas, válidas los 2 días." },
    { id:"frater-20", nombre:"Jueves de Frater · 20 manillas", precio:3000, antes:null, cupo:12,
      manillas:20, categoria:"mesa",
      desc:"Tu mesa para el jueves de frater, para el grupo grande.",
      incluye:"Bs 3.000 en consumo + 20 manillas + 2 baldes Amstel." },
    { id:"frater-10", nombre:"Jueves de Frater · 10 manillas", precio:2000, antes:null, cupo:18,
      manillas:10, categoria:"mesa",
      desc:"Tu mesa para el jueves de frater.",
      incluye:"Bs 2.000 en consumo + 10 manillas + 2 baldes Amstel." },
    { id:"viernes", nombre:"Combo Viernes", precio:1500, antes:null, cupo:20,
      manillas:5, categoria:"mesa",
      desc:"Tu mesa para el viernes.",
      incluye:"Bs 1.500 en consumo + 5 manillas por 1 día." }
  ],
};
