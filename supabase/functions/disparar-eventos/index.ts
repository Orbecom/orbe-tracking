// Orbe Tracking — envia à Meta os eventos de conversão de uma etapa da jornada
// Chamado pelo banco (gatilho leads_registrar_etapa, via pg_net) sempre que um lead entra numa etapa com eventos.
// Body: { lead_id, etapa_id, venda_id? }   Cabeçalho: x-cron-secret
// Envio pela API de Conversões para mensagens (business_messaging): WhatsApp, Messenger e Instagram.
// Cada envio fica registrado em eventos_disparados (o painel mostra no detalhe do lead).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// A Meta só aceita eventos dos últimos 7 dias
const JANELA_MS = 7 * 86400_000 - 3600_000;

async function tokenDaPagina(base: string, pageId: string | null) {
  const token = Deno.env.get("META_ACCESS_TOKEN");
  if (!token || !pageId) return null;
  const r = await fetch(`${base}/${pageId}?fields=access_token&access_token=${token}`);
  return r.ok ? ((await r.json())?.access_token ?? null) : null;
}

// Quem é a pessoa, do jeito que a Meta reconhece em cada canal (null = não dá para atribuir)
async function destino(lead: any, cliente: any, base: string) {
  const tokens: (string | null)[] = [];
  let canal: string, userData: Record<string, unknown>;
  if (lead.canal === "messenger") {
    if (!lead.fb_psid || !cliente.page_id) return null;
    canal = "messenger";
    userData = { page_id: cliente.page_id, page_scoped_user_id: lead.fb_psid };
    tokens.push(Deno.env.get("META_ACCESS_TOKEN") ?? null, await tokenDaPagina(base, cliente.page_id));
  } else if (lead.canal === "instagram") {
    if (!lead.ig_sid || String(lead.ig_sid).startsWith("manual:") || !cliente.ig_account_id) return null;
    canal = "instagram";
    userData = { ig_account_id: cliente.ig_account_id, ig_sid: lead.ig_sid };
    tokens.push(Deno.env.get("META_ACCESS_TOKEN") ?? null, await tokenDaPagina(base, cliente.page_id));
  } else {
    if (!lead.ctwa_clid) return null; // WhatsApp orgânico: nada a atribuir
    canal = "whatsapp";
    userData = { whatsapp_business_account_id: cliente.waba_id, ctwa_clid: lead.ctwa_clid };
    // Token da conta do cliente (conectada pelo "Conectar WhatsApp") e, como reserva, o token da Orbe
    const { data: tokenCliente } = await admin.rpc("ler_token_wa", { p_cliente: lead.cliente_id });
    tokens.push(tokenCliente as string | null, Deno.env.get("META_ACCESS_TOKEN") ?? null);
  }
  // Messenger/Instagram exigem um conjunto de dados ligado à página (criado pelo assinar-pagina)
  const dataset = canal === "whatsapp" ? cliente.dataset_id : (cliente.dataset_pagina_id ?? cliente.dataset_id);
  return { canal, userData, dataset, tokens: [...new Set(tokens.filter(Boolean))] as string[] };
}

async function enviar(base: string, d: NonNullable<Awaited<ReturnType<typeof destino>>>, evento: Record<string, unknown>) {
  if (!d.dataset) return "Cliente sem conjunto de dados cadastrado";
  if (!d.tokens.length) return "Sem token de acesso para enviar à Meta";
  let erro = "";
  for (const token of d.tokens) {
    const resp = await fetch(`${base}/${d.dataset}/events`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ data: [evento], access_token: token }),
    });
    if (resp.ok) return null;
    erro = `Meta ${resp.status}: ${(await resp.text()).slice(0, 400)}`;
  }
  return erro;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ erro: "Método não permitido" }, 405);
  const { data: segredo } = await admin.rpc("ler_config", { p_chave: "cron_secret" });
  if (!segredo || req.headers.get("x-cron-secret") !== segredo) return json({ erro: "Não autorizado" }, 401);

  let body: any;
  try { body = await req.json(); } catch { return json({ erro: "JSON inválido" }, 400); }
  const { lead_id, etapa_id, venda_id } = body ?? {};
  if (typeof lead_id !== "string" || typeof etapa_id !== "string") return json({ erro: "lead_id e etapa_id obrigatórios" }, 400);

  const [{ data: lead }, { data: etapa }] = await Promise.all([
    admin.from("leads").select("id, cliente_id, canal, origem, ctwa_clid, fb_psid, ig_sid").eq("id", lead_id).maybeSingle(),
    admin.from("etapas").select("id, cliente_id, eventos").eq("id", etapa_id).maybeSingle(),
  ]);
  if (!lead || !etapa || etapa.cliente_id !== lead.cliente_id) return json({ erro: "Lead ou etapa não encontrados" }, 404);
  if (!etapa.eventos?.length || lead.origem === "manual") return json({ ok: true, enviados: 0 });

  const { data: cliente } = await admin.from("clientes")
    .select("dataset_id, dataset_pagina_id, waba_id, page_id, ig_account_id, moeda").eq("id", lead.cliente_id).single();
  const { data: versao } = await admin.rpc("ler_config", { p_chave: "graph_version" });
  const base = `https://graph.facebook.com/${versao ?? "v23.0"}`;
  const d = await destino(lead, cliente, base);
  if (!d) return json({ ok: true, enviados: 0, motivo: "contato sem identificação de anúncio" });

  const resultado: Record<string, string> = {};
  for (const nome of etapa.eventos as string[]) {
    let eventId: string, quando = Date.now(), valor: number | null = null, venda: any = null;
    if (nome === "Purchase") {
      // A venda que acabou de ser registrada (ou, se não veio, a mais recente do lead)
      const q = admin.from("vendas").select("id, valor, vendido_em, capi_enviado_em");
      const { data } = venda_id
        ? await q.eq("id", venda_id).maybeSingle()
        : await q.eq("lead_id", lead.id).order("vendido_em", { ascending: false }).limit(1).maybeSingle();
      venda = data;
      if (!venda) { resultado[nome] = "sem venda"; continue; }
      if (venda.capi_enviado_em) { resultado[nome] = "já enviado"; continue; } // enviado pela versão anterior (marcar-venda)
      eventId = `venda-${venda.id}`;
      valor = Number(venda.valor);
      quando = Math.max(new Date(venda.vendido_em).getTime(), Date.now() - JANELA_MS);
    } else {
      eventId = `etapa-${lead.id}-${nome}`; // uma vez por lead
    }

    const { data: anterior } = await admin.from("eventos_disparados").select("status").eq("event_id", eventId).maybeSingle();
    if (anterior?.status === "enviado") { resultado[nome] = "já enviado"; continue; }

    const erro = await enviar(base, d, {
      event_name: nome,
      event_time: Math.floor(quando / 1000),
      event_id: eventId,
      action_source: "business_messaging",
      messaging_channel: d.canal,
      user_data: d.userData,
      ...(valor != null ? { custom_data: { currency: cliente.moeda ?? "BRL", value: valor } } : {}),
    });

    const agora = new Date().toISOString();
    await admin.from("eventos_disparados").upsert({
      cliente_id: lead.cliente_id, lead_id: lead.id, venda_id: venda?.id ?? null, etapa_id: etapa.id,
      evento: nome, event_id: eventId, status: erro ? "erro" : "enviado", detalhe: erro, valor, atualizado_em: agora,
    }, { onConflict: "event_id" });
    if (venda) {
      // Mantém os campos antigos em dia (a versão anterior do painel lê deles)
      await admin.from("vendas").update({ capi_erro: erro, ...(erro ? {} : { capi_enviado_em: agora }) }).eq("id", venda.id);
      await admin.from("leads").update({ capi_erro: erro, ...(erro ? {} : { capi_enviado_em: agora }) }).eq("id", lead.id);
    }
    resultado[nome] = erro ? "erro" : "enviado";
  }
  return json({ ok: true, resultado });
});
