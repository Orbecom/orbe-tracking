// Service worker mínimo: deixa o app instalável e não guarda nada em cache,
// assim o painel sempre abre com os dados e a versão mais recentes.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
