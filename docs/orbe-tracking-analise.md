# Orbe Tracking — atualizações

Continuação do documento "Orbe tracking analise instagram messenger". Cada bloco abaixo é uma etapa de trabalho, da mais recente para a mais antiga.

---

## 06/11/2026 — Comparação com o Tintim, Jornada de compra e Painel

### 1. O que é o Tintim (concorrente)

Ferramenta brasileira (tintim.app) que rastreia de onde vêm as conversas de WhatsApp e quais viraram venda, e devolve essas vendas para a Meta e o Google Ads. Mais de 5.800 empresas. Só WhatsApp: não tem Instagram Direct nem Messenger.

**Preços:** Inicial R$ 197/mês · Escala R$ 297/mês (webhook, envio para Meta e Google Ads, acesso de terceiros) · Agências sob consulta. Teste grátis de 7 dias. 1 número de WhatsApp por plano, usuários ilimitados.

**Módulos do Tintim**

| Módulo | Como funciona |
|---|---|
| Conexão WhatsApp | 3 tipos: QR Code "Lite" (não oficial, espelha o WhatsApp Web), Coexistência (oficial, como o Orbe) e API oficial via plataformas de atendimento (Kommo, Huggy, Botconversa, Infobip e mais de 30) |
| Origem do lead | 4 origens: Meta Ads, Google Ads, Outras origens, Sem rastreio. Anúncio direto para WhatsApp (lê o ID do anúncio na 1ª mensagem); "mensagem rastreável" com código invisível; link rastreável (encurtado, QR Code, frases personalizadas); pixel no site que repassa UTMs e gclid/fbclid ao botão de WhatsApp; parâmetro `tintim_fbid={{ad.id}}` nos anúncios |
| Jornada de compra | Etapas configuráveis; muda de etapa quando o atendente envia uma frase combinada; lê o valor da venda na própria mensagem ("R$ 297"); data de venda retroativa; histórico de etapas; kanban; mudança em lote; tempo de primeira resposta |
| IA ("LUPA IA") | Inspetor de Vendas: lê as conversas de madrugada e sugere vendas com nota de confiança (90–92% de acerto) para aprovar. Inspetor de Campanhas: campanha/conjunto/anúncio com gasto, CTR, CPM, CPC × leads, vendas, ROAS. Auditoria de conversas |
| Envio de conversões | Meta (API de Conversões): eventos por etapa, com telefone, nome, gênero, cidade/CEP pelo IP. Google Ads: conversões offline automáticas (gclid, valor, ID único, espera de 6 h) |
| Integrações | Webhooks (conversa criada/alterada, origem alterada, nova mensagem), API para mudar etapa, Kommo, RD Station, Google Sheets via Make |
| Relatórios e contas | Dashboard com comparação de períodos e funil; exportação CSV; filtros salvos; gerenciador de contas da agência; acesso do cliente como "Operador" |

**Onde o Orbe está à frente:** Instagram Direct e Messenger; conexão só oficial (sem risco do QR Code); recompra (mesmo cliente comprando de novo); atendente com IA que conversa (Orbia); aviso de lead novo em tempo real; não guarda o texto das conversas.

**O que vale trazer para o Orbe (por impacto)**
1. Jornada com etapas e eventos por etapa — **feito (06/11)**
2. Frase combinada do atendente e valor lido da mensagem
3. Link rastreável, pixel no site e `tintim_fbid` (cobre site e Google)
4. Detecção de vendas por IA (mesma base da Orbia)
5. Envio automático de conversões ao Google Ads
6. Webhooks e exportação CSV

### 2. Jornada de compra (implementado)

- **Etapas por cliente:** Entrada (Novo), intermediárias (ex.: Negociando, Orçamento enviado — quantas quiser), Venda (Vendido), Perdido e Interno. Os 5 clientes já ganharam as etapas padrão.
- **Configuração (só agência):** botão "Etapas do funil" na aba Leads — renomear, criar, ordenar e remover etapas intermediárias, escolher os eventos da Meta de cada etapa e o valor padrão da venda.
- **Eventos para a Meta por etapa:** Lead, Lead qualificado, Iniciou a compra, Adicionou ao carrinho, Viu o conteúdo e Compra (com valor). Só para leads de anúncio no WhatsApp, Instagram e Messenger. Padrão atual: só "Compra" na etapa Vendido (igual a antes). Recomendado ligar "Lead" na entrada e "Lead qualificado" numa intermediária.
- **Leads:** visão em Lista ou Colunas (kanban com arrastar e soltar); venda com valor e data (pode ser retroativa); detalhe do lead com histórico de etapas (manual ou automático) e eventos enviados à Meta, inclusive erros.
- **Compatibilidade:** o status antigo continua e acompanha a etapa; o webhook não mudou.

### 3. Painel (Relatório em formato de dashboard)

- Indicadores com comparação com o período anterior: leads, taxa de conversão, vendas, faturamento, investido, custo por lead de anúncio, custo por venda e ROAS.
- Gráficos: leads por dia (anúncio, orgânico, manual) e faturamento por dia, com detalhes ao passar o mouse/tocar.
- Funil (quantos chegaram em cada etapa e % que avançou) e divisão por canal (WhatsApp, Instagram, Messenger).
- Embaixo, a tabela por anúncio e por campanha que já existia.

### 4. Situação

| Parte | Status |
|---|---|
| Banco de dados (etapas, histórico, eventos, funções do painel) | No ar desde 06/11 |
| Função `disparar-eventos` (envio à Meta por etapa) | No ar desde 06/11 |
| Tela nova (Leads + Painel) | No ar em tracking.orbemedia.com.br desde 06/11 |
| Envio real de eventos além de "Compra" | A verificar no primeiro uso (aparece no detalhe do lead) |

### 5. Próximos passos

- Conferir no uso real: arrastar leads entre etapas, registrar uma venda e ver o evento "enviado" no detalhe do lead.
- Ligar os eventos "Lead" (entrada) e "Lead qualificado" (intermediária) nos clientes com anúncio.
- Módulo 2: frase combinada do atendente e valor lido da mensagem (WhatsApp por coexistência).
- Depois: link rastreável e pixel no site; detecção de vendas por IA; Google Ads.
