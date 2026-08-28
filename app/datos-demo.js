/* Datos del evento para MODO 'demo'. En modo 'supabase' esto no se usa:
   el evento, sus tipos, su fase vigente y sus mesas salen de la base.
   Las mesas llevan x/y/w en porcentaje, igual que la tabla `mesas`. */
window.DATOS_DEMO = {
  organizador: { nombre: "Amstel", fee_pct: 0.07, fee_fijo: 3, fee_piso: 5 },
  evento: {
    id: "e5b1f0a2-0000-4000-8000-000000000001",
    marca_1: "Amstel", marca_2: "Ferial",
    lugar: "Feria Exposición · Santa Cruz de la Sierra",
    fecha_txt: "SÁB 12 SEP · 21:00",
    bajada: "Una noche, tres escenarios y la chopería más grande del año. Elegí tu entrada o agarrá tu mesa antes de que se vaya.",
    datos: [["Puertas","21:00"],["Edad mínima","18"],["Mesas","24 en dos plantas"],["Pago","QR, tarjeta y débito"]],
    tope_entradas_orden: 10
  },
  fase: { nombre: "Preventa 2", hasta_txt: "hasta el 5 de septiembre" },
  tipos: [
    { id:"gen",  nombre:"General", precio:120, antes:150, cupo:340, manillas:1,
      desc:"Acceso general a los tres escenarios." },
    { id:"vip",  nombre:"VIP", precio:250, antes:290, cupo:18, manillas:1,
      desc:"Sector elevado, barra propia y dos Amstel de bienvenida." },
    { id:"club", nombre:"Amstel Club", precio:420, antes:null, cupo:6, manillas:1,
      desc:"Terraza cerrada, atención en el lugar y acceso al backstage." }
  ],
  plantas: [
    { id:"baja", nombre:"Planta baja", barra:{ texto:"Barra principal", left:"4%", top:"84%", width:"92%", height:"8%" } },
    { id:"alta", nombre:"Planta alta", barra:{ texto:"Chopería", left:"4%", top:"6%", width:"20%", height:"22%" } }
  ],
  mesas: [
    { et:"M1",  planta:"baja", x:16, y:26, w:7.4, cat:"mesa",   precio:1200, manillas:8,  estado:"disponible" },
    { et:"M2",  planta:"baja", x:28, y:22, w:7.4, cat:"mesa",   precio:1200, manillas:8,  estado:"vendida" },
    { et:"M3",  planta:"baja", x:40, y:20, w:7.4, cat:"mesa",   precio:1200, manillas:8,  estado:"disponible" },
    { et:"M4",  planta:"baja", x:52, y:20, w:7.4, cat:"mesa",   precio:1200, manillas:8,  estado:"disponible" },
    { et:"M5",  planta:"baja", x:64, y:22, w:7.4, cat:"mesa",   precio:1200, manillas:8,  estado:"bloqueada" },
    { et:"M6",  planta:"baja", x:76, y:26, w:7.4, cat:"mesa",   precio:1200, manillas:8,  estado:"disponible" },
    { et:"M7",  planta:"baja", x:18, y:44, w:7.4, cat:"mesa",   precio:1000, manillas:8,  estado:"disponible" },
    { et:"M8",  planta:"baja", x:31, y:42, w:7.4, cat:"mesa",   precio:1000, manillas:8,  estado:"vendida" },
    { et:"M9",  planta:"baja", x:44, y:41, w:7.4, cat:"mesa",   precio:1000, manillas:8,  estado:"disponible" },
    { et:"M10", planta:"baja", x:57, y:41, w:7.4, cat:"mesa",   precio:1000, manillas:8,  estado:"disponible" },
    { et:"M11", planta:"baja", x:70, y:42, w:7.4, cat:"mesa",   precio:1000, manillas:8,  estado:"disponible" },
    { et:"M12", planta:"baja", x:83, y:44, w:7.4, cat:"mesa",   precio:1000, manillas:8,  estado:"vendida" },
    { et:"L1",  planta:"baja", x:24, y:66, w:10,  cat:"lounge", precio:2500, manillas:12, estado:"disponible" },
    { et:"L2",  planta:"baja", x:50, y:68, w:10,  cat:"lounge", precio:2800, manillas:12, estado:"disponible" },
    { et:"L3",  planta:"baja", x:76, y:66, w:10,  cat:"lounge", precio:2500, manillas:12, estado:"vendida" },
    { et:"A1",  planta:"alta", x:20, y:24, w:8,   cat:"mesa",   precio:1500, manillas:8,  estado:"disponible" },
    { et:"A2",  planta:"alta", x:36, y:20, w:8,   cat:"mesa",   precio:1500, manillas:8,  estado:"disponible" },
    { et:"A3",  planta:"alta", x:56, y:20, w:8,   cat:"mesa",   precio:1500, manillas:8,  estado:"vendida" },
    { et:"A4",  planta:"alta", x:72, y:24, w:8,   cat:"mesa",   precio:1500, manillas:8,  estado:"disponible" },
    { et:"A5",  planta:"alta", x:24, y:46, w:8,   cat:"mesa",   precio:1300, manillas:8,  estado:"disponible" },
    { et:"A6",  planta:"alta", x:44, y:44, w:8,   cat:"mesa",   precio:1300, manillas:8,  estado:"bloqueada" },
    { et:"A7",  planta:"alta", x:64, y:46, w:8,   cat:"mesa",   precio:1300, manillas:8,  estado:"disponible" },
    { et:"P1",  planta:"alta", x:32, y:70, w:12,  cat:"lounge", precio:3600, manillas:14, estado:"disponible" },
    { et:"P2",  planta:"alta", x:66, y:70, w:12,  cat:"lounge", precio:3600, manillas:14, estado:"disponible" }
  ]
};
