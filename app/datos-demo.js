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
    datos: [["Puertas","21:00"],["Edad mínima","18"],["Mesas","24 disponibles"],["Pago","QR, tarjeta y débito"]],
    tope_entradas_orden: 10
  },
  fase: { nombre: "Preventa 2", hasta_txt: "hasta el 5 de septiembre" },
  tipos: [
    { id:"gen",  nombre:"General", precio:120, antes:150, cupo:340, manillas:1,
      categoria:"entrada", desc:"Acceso general a los tres escenarios." },
    { id:"vip",  nombre:"VIP", precio:250, antes:290, cupo:18, manillas:1,
      categoria:"entrada", desc:"Sector elevado, barra propia y dos Amstel de bienvenida." },
    { id:"club", nombre:"Amstel Club", precio:420, antes:null, cupo:6, manillas:1,
      categoria:"entrada",
      desc:"Terraza cerrada, atención en el lugar y acceso al backstage." },
    { id:"branca", nombre:"Branca Lounge", precio:3000, antes:null, cupo:9, manillas:10,
      categoria:"mesa",
      desc:"Sector premium, con excelente ubicación y pensado para disfrutar la noche con mayor comodidad y una experiencia de mesa superior.",
      incluye:"Todo en consumo + 1 botella de Fernet Branca de cortesía." },
    { id:"mesa", nombre:"Mesas", precio:2000, antes:null, cupo:15, manillas:8,
      categoria:"mesa",
      desc:"Un espacio cómodo y estratégico para disfrutar el evento con tu grupo y contar con tu propia mesa durante toda la noche.",
      incluye:"Todo en consumo." }
  ],
};
