-- Orbe Tracking — Jornada de compra
-- Etapas configuráveis por cliente, histórico de mudanças de etapa, registro dos eventos enviados à Meta
-- e a função do painel (relatório em formato de dashboard).
--
-- Compatibilidade: a coluna leads.status continua existindo e fica sincronizada com a etapa (nos dois sentidos),
-- então o webhook e a versão anterior do painel seguem funcionando sem mudança.

-- ---------------------------------------------------------------------------
-- Etapas
-- ---------------------------------------------------------------------------
-- entrada   = onde todo contato novo cai (uma por cliente)
-- andamento = etapas intermediárias do funil (quantas quiser)
-- venda     = a etapa de venda (uma por cliente)
-- perdido   = fora do funil, não comprou (uma por cliente)
-- interno   = equipe, família, fornecedores: não conta como lead (uma por cliente)
create type public.tipo_etapa as enum ('entrada', 'andamento', 'venda', 'perdido', 'interno');

create table public.etapas (
  id           uuid primary key default gen_random_uuid(),
  cliente_id   uuid not null references public.clientes(id) on delete cascade,
  nome         text not null check (length(btrim(nome)) between 1 and 40),
  tipo         public.tipo_etapa not null,
  ordem        integer not null default 0,
  -- Eventos enviados à Meta (API de Conversões para mensagens) quando o lead entra na etapa
  eventos      text[] not null default '{}'
               check (eventos <@ array['LeadSubmitted','QualifiedLead','InitiateCheckout','AddToCart','ViewContent','Purchase']),
  -- Valor usado na venda quando ninguém informa outro
  valor_padrao numeric check (valor_padrao is null or valor_padrao > 0),
  criado_em    timestamptz not null default now(),
  check (not ('Purchase' = any(eventos)) or tipo = 'venda'),
  check (tipo in ('entrada', 'andamento', 'venda') or eventos = '{}'),
  check (valor_padrao is null or tipo = 'venda')
);
create unique index etapas_tipo_unico on public.etapas (cliente_id, tipo) where tipo <> 'andamento';
create index etapas_cliente_ordem on public.etapas (cliente_id, ordem);

-- Tipo e cliente de uma etapa não mudam depois de criada (o status dos leads depende deles)
create or replace function privado.etapas_proteger() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.tipo <> old.tipo or new.cliente_id <> old.cliente_id then
    raise exception 'O tipo da etapa não pode ser alterado';
  end if;
  return new;
end $$;
create trigger etapas_proteger before update on public.etapas
  for each row execute function privado.etapas_proteger();

create or replace function privado.eh_agencia(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.membros where cliente_id = c and user_id = auth.uid() and papel = 'agencia')
$$;

alter table public.etapas enable row level security;
create policy "membro vê etapas" on public.etapas for select to authenticated
  using (privado.eh_membro(cliente_id));
create policy "agência cria etapas" on public.etapas for insert to authenticated
  with check (privado.eh_agencia(cliente_id) and tipo = 'andamento');
create policy "agência edita etapas" on public.etapas for update to authenticated
  using (privado.eh_agencia(cliente_id)) with check (privado.eh_agencia(cliente_id));
-- Só etapas intermediárias podem ser removidas (e só sem leads nelas: a chave estrangeira impede)
create policy "agência remove etapas" on public.etapas for delete to authenticated
  using (privado.eh_agencia(cliente_id) and tipo = 'andamento');

-- Etapas padrão: equivalem aos status que já existiam
create or replace function privado.criar_etapas_padrao(c uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.etapas (cliente_id, nome, tipo, ordem, eventos) values
    (c, 'Novo',       'entrada',   10, '{}'),
    (c, 'Negociando', 'andamento', 20, '{}'),
    (c, 'Vendido',    'venda',     30, '{Purchase}'),
    (c, 'Perdido',    'perdido',   90, '{}'),
    (c, 'Interno',    'interno',   99, '{}')
  on conflict do nothing
$$;

create or replace function privado.etapas_novo_cliente() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform privado.criar_etapas_padrao(new.id);
  return new;
end $$;
create trigger orbe_etapas_padrao after insert on public.clientes
  for each row execute function privado.etapas_novo_cliente();

select privado.criar_etapas_padrao(id) from public.clientes;

-- ---------------------------------------------------------------------------
-- Etapa do lead
-- ---------------------------------------------------------------------------
alter table public.leads add column etapa_id uuid references public.etapas(id);
create index leads_etapa on public.leads (etapa_id);

-- Preenche a etapa dos leads que já existem a partir do status atual
update public.leads l set etapa_id = e.id
from public.etapas e
where e.cliente_id = l.cliente_id
  and e.tipo = (case l.status when 'novo' then 'entrada' when 'negociando' then 'andamento'
                  when 'vendido' then 'venda' when 'perdido' then 'perdido' else 'interno' end)::public.tipo_etapa;

create or replace function privado.tipo_do_status(s public.status_lead) returns public.tipo_etapa
language sql immutable as $$
  select (case s when 'novo' then 'entrada' when 'negociando' then 'andamento'
            when 'vendido' then 'venda' when 'perdido' then 'perdido' else 'interno' end)::public.tipo_etapa
$$;

create or replace function privado.status_do_tipo(t public.tipo_etapa) returns public.status_lead
language sql immutable as $$
  select (case t when 'entrada' then 'novo' when 'andamento' then 'negociando'
            when 'venda' then 'vendido' when 'perdido' then 'perdido' else 'interno' end)::public.status_lead
$$;

-- Mantém status e etapa sincronizados:
-- - mudou a etapa  -> o status acompanha o tipo da etapa
-- - mudou o status (webhook, versão antiga do painel) -> vai para a primeira etapa daquele tipo
--   (se a etapa atual já é desse tipo, fica onde está)
create or replace function privado.leads_sincronizar_etapa() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  t public.tipo_etapa;
  atual public.tipo_etapa;
begin
  if new.etapa_id is not null and (tg_op = 'INSERT' or new.etapa_id is distinct from old.etapa_id) then
    select tipo into t from public.etapas where id = new.etapa_id and cliente_id = new.cliente_id;
    if t is null then raise exception 'Etapa inválida para este cliente'; end if;
    new.status := privado.status_do_tipo(t);
  elsif new.etapa_id is null or (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    t := privado.tipo_do_status(new.status);
    if new.etapa_id is not null then
      select tipo into atual from public.etapas where id = new.etapa_id;
    end if;
    if atual is distinct from t then
      select id into new.etapa_id from public.etapas
      where cliente_id = new.cliente_id and tipo = t
      order by ordem, criado_em limit 1;
    end if;
  end if;
  return new;
end $$;
create trigger leads_sincronizar_etapa before insert or update on public.leads
  for each row execute function privado.leads_sincronizar_etapa();

-- ---------------------------------------------------------------------------
-- Histórico de mudanças de etapa
-- ---------------------------------------------------------------------------
create table public.etapa_historico (
  id          bigint generated always as identity primary key,
  lead_id     uuid not null references public.leads(id) on delete cascade,
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  de_etapa    uuid references public.etapas(id) on delete set null,
  para_etapa  uuid references public.etapas(id) on delete set null,
  -- manual = alguém mudou no painel; sistema = automático (contato novo, voltou a chamar...)
  origem      text not null check (origem in ('manual', 'automatico', 'sistema', 'api')),
  usuario_id  uuid references auth.users(id) on delete set null,
  criado_em   timestamptz not null default now()
);
create index etapa_historico_lead on public.etapa_historico (lead_id, criado_em);
create index etapa_historico_cliente on public.etapa_historico (cliente_id, criado_em);
alter table public.etapa_historico enable row level security;
create policy "membro vê histórico" on public.etapa_historico for select to authenticated
  using (privado.eh_membro(cliente_id));

-- Histórico inicial dos leads que já existiam
insert into public.etapa_historico (lead_id, cliente_id, de_etapa, para_etapa, origem, criado_em)
select id, cliente_id, null, etapa_id, 'sistema', criado_em from public.leads where etapa_id is not null;

-- ---------------------------------------------------------------------------
-- Eventos enviados à Meta
-- ---------------------------------------------------------------------------
create table public.eventos_disparados (
  id          bigint generated always as identity primary key,
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  lead_id     uuid references public.leads(id) on delete cascade,
  venda_id    uuid references public.vendas(id) on delete set null,
  etapa_id    uuid references public.etapas(id) on delete set null,
  evento      text not null,
  plataforma  text not null default 'meta',
  -- Purchase: venda-<id da venda> (o mesmo formato de antes); demais: etapa-<lead>-<evento> (uma vez por lead)
  event_id    text not null unique,
  status      text not null check (status in ('enviado', 'erro')),
  detalhe     text,
  valor       numeric,
  criado_em   timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index eventos_disparados_lead on public.eventos_disparados (lead_id, criado_em);
alter table public.eventos_disparados enable row level security;
create policy "membro vê eventos" on public.eventos_disparados for select to authenticated
  using (privado.eh_membro(cliente_id));

-- Lead que a Meta consegue reconhecer: WhatsApp vindo de anúncio (ctwa_clid), Instagram e Messenger
create or replace function privado.lead_atribuivel(l public.leads) returns boolean
language sql immutable as $$
  select l.origem <> 'manual' and (
    (l.canal = 'whatsapp' and l.ctwa_clid is not null)
    or (l.canal = 'instagram' and l.ig_sid is not null and l.ig_sid not like 'manual:%')
    or (l.canal = 'messenger' and l.fb_psid is not null))
$$;

-- Registra a mudança no histórico e, se a etapa tiver eventos, pede o envio à função disparar-eventos
-- (pg_net só envia depois do commit; uma falha no envio não desfaz a mudança de etapa)
create or replace function privado.leads_registrar_etapa() returns trigger
language plpgsql security definer set search_path = public, privado as $$
declare
  ev text[];
begin
  insert into public.etapa_historico (lead_id, cliente_id, de_etapa, para_etapa, origem, usuario_id)
  values (new.id, new.cliente_id, case when tg_op = 'UPDATE' then old.etapa_id end, new.etapa_id,
          coalesce(nullif(current_setting('orbe.origem_etapa', true), ''),
                   case when auth.uid() is null then 'sistema' else 'manual' end),
          auth.uid());

  select eventos into ev from public.etapas where id = new.etapa_id;
  if coalesce(cardinality(ev), 0) > 0 and privado.lead_atribuivel(new) then
    perform net.http_post(
      url := 'https://kpdurajnbnpdnjofwefn.supabase.co/functions/v1/disparar-eventos',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select valor from privado.config where chave = 'cron_secret')),
      body := jsonb_build_object(
        'lead_id', new.id, 'etapa_id', new.etapa_id,
        'venda_id', nullif(current_setting('orbe.venda_id', true), '')),
      timeout_milliseconds := 30000);
  end if;
  return null;
end $$;
-- Dois gatilhos porque OLD não existe no insert; no update, só quando a etapa mudou
create trigger leads_registrar_etapa_ins after insert on public.leads
  for each row when (new.etapa_id is not null)
  execute function privado.leads_registrar_etapa();
create trigger leads_registrar_etapa_upd after update on public.leads
  for each row when (new.etapa_id is distinct from old.etapa_id and new.etapa_id is not null)
  execute function privado.leads_registrar_etapa();

-- ---------------------------------------------------------------------------
-- Mover etapa (painel) e desfazer venda
-- ---------------------------------------------------------------------------
create or replace function public.mover_etapa(
  p_lead uuid, p_etapa uuid, p_valor numeric default null, p_vendido_em timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare
  l public.leads;
  e public.etapas;
  v_valor numeric;
  v_quando timestamptz;
  v_venda uuid;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null or not privado.eh_membro(l.cliente_id) then raise exception 'Lead não encontrado'; end if;
  select * into e from public.etapas where id = p_etapa and cliente_id = l.cliente_id;
  if e.id is null then raise exception 'Etapa inválida'; end if;

  perform set_config('orbe.origem_etapa', 'manual', true);

  if e.tipo = 'venda' then
    if l.status = 'vendido' then raise exception 'Essa venda já foi registrada'; end if;
    v_valor := coalesce(p_valor, e.valor_padrao);
    if v_valor is null or v_valor <= 0 or v_valor > 10000000 then raise exception 'Informe um valor de venda válido'; end if;
    v_quando := coalesce(p_vendido_em, now());
    if v_quando > now() + interval '10 minutes' then raise exception 'A data da venda não pode ser no futuro'; end if;
    if v_quando < l.criado_em - interval '1 day' then raise exception 'A data da venda é anterior ao primeiro contato'; end if;

    insert into public.vendas (lead_id, cliente_id, valor, ad_id, vendido_em)
    values (l.id, l.cliente_id, v_valor, l.ad_id, v_quando) returning id into v_venda;
    perform set_config('orbe.venda_id', v_venda::text, true);
    update public.leads set etapa_id = e.id, valor_venda = v_valor, vendido_em = v_quando,
           compras = coalesce(compras, 0) + 1
    where id = l.id;
  else
    if l.etapa_id = e.id then return jsonb_build_object('ok', true, 'sem_mudanca', true); end if;
    update public.leads set etapa_id = e.id where id = l.id;
  end if;

  return jsonb_build_object('ok', true, 'tipo', e.tipo, 'venda_id', v_venda, 'valor', v_valor,
    'envia_meta', cardinality(e.eventos) > 0 and privado.lead_atribuivel(l));
end $$;

-- Desfaz a venda mais recente do lead (as anteriores continuam valendo) e volta para a primeira etapa intermediária
create or replace function public.desfazer_venda(p_lead uuid) returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare
  l public.leads;
  ultima public.vendas;
  anterior public.vendas;
  enviado boolean;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null or not privado.eh_membro(l.cliente_id) then raise exception 'Lead não encontrado'; end if;

  select * into ultima from public.vendas where lead_id = l.id order by vendido_em desc limit 1;
  if ultima.id is not null then
    select exists (select 1 from public.eventos_disparados where venda_id = ultima.id and status = 'enviado')
           or ultima.capi_enviado_em is not null into enviado;
    delete from public.vendas where id = ultima.id;
  end if;
  select * into anterior from public.vendas where lead_id = l.id order by vendido_em desc limit 1;

  perform set_config('orbe.origem_etapa', 'manual', true);
  update public.leads set status = 'negociando',
         valor_venda = anterior.valor, vendido_em = anterior.vendido_em,
         compras = greatest(0, coalesce(compras, 1) - 1)
  where id = l.id;

  return jsonb_build_object('ok', true, 'aviso',
    case when enviado then 'Venda desfeita aqui. O evento já enviado à Meta não é removido.' end);
end $$;

revoke execute on function public.mover_etapa(uuid, uuid, numeric, timestamptz) from public, anon;
revoke execute on function public.desfazer_venda(uuid) from public, anon;
grant execute on function public.mover_etapa(uuid, uuid, numeric, timestamptz) to authenticated;
grant execute on function public.desfazer_venda(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Painel (dashboard): período atual x período anterior de mesmo tamanho, série diária e funil
-- Usa o RLS de quem chama (só enxerga clientes dos quais é membro).
-- ---------------------------------------------------------------------------
create or replace function public.painel(p_cliente uuid, p_inicio date, p_fim date) returns jsonb
language sql stable set search_path = public as $$
  with
  per as (
    select p_fim - p_inicio + 1 as dias
  ),
  periodos as (
    select 'atual' as p, p_inicio as ini, p_fim as fim
    union all
    select 'anterior', p_inicio - (select dias from per), p_inicio - 1
  ),
  ld as (
    select l.*, (l.criado_em at time zone 'America/Sao_Paulo')::date as dia
    from leads l
    where l.cliente_id = p_cliente and l.status <> 'interno'
      and (l.criado_em at time zone 'America/Sao_Paulo')::date between p_inicio - (select dias from per) and p_fim
  ),
  vd as (
    select v.*, (v.vendido_em at time zone 'America/Sao_Paulo')::date as dia,
           coalesce(v.ad_id, l.ad_id) is not null as de_anuncio
    from vendas v join leads l on l.id = v.lead_id
    where v.cliente_id = p_cliente
      and (v.vendido_em at time zone 'America/Sao_Paulo')::date between p_inicio - (select dias from per) and p_fim
  ),
  md as (
    select * from metricas_diarias
    where cliente_id = p_cliente and data between p_inicio - (select dias from per) and p_fim
  ),
  resumo as (
    select p.p, jsonb_build_object(
      'leads',          (select count(*) from ld where dia between p.ini and p.fim),
      'leads_anuncio',  (select count(*) from ld where dia between p.ini and p.fim and origem = 'anuncio'),
      'leads_organico', (select count(*) from ld where dia between p.ini and p.fim and origem = 'organico'),
      'leads_manual',   (select count(*) from ld where dia between p.ini and p.fim and origem = 'manual'),
      'whatsapp',       (select count(*) from ld where dia between p.ini and p.fim and canal = 'whatsapp'),
      'instagram',      (select count(*) from ld where dia between p.ini and p.fim and canal = 'instagram'),
      'messenger',      (select count(*) from ld where dia between p.ini and p.fim and canal = 'messenger'),
      'perdidos',       (select count(*) from ld where dia between p.ini and p.fim and status = 'perdido'),
      'vendas',         (select count(*) from vd where dia between p.ini and p.fim),
      'faturamento',    (select coalesce(sum(valor), 0) from vd where dia between p.ini and p.fim),
      'vendas_anuncio', (select count(*) from vd where dia between p.ini and p.fim and de_anuncio),
      'faturamento_anuncio', (select coalesce(sum(valor), 0) from vd where dia between p.ini and p.fim and de_anuncio),
      'gasto',          (select coalesce(sum(gasto), 0) from md where data between p.ini and p.fim),
      'impressoes',     (select coalesce(sum(impressoes), 0) from md where data between p.ini and p.fim),
      'cliques',        (select coalesce(sum(cliques), 0) from md where data between p.ini and p.fim),
      'mensagens',      (select coalesce(sum(mensagens), 0) from md where data between p.ini and p.fim)
    ) as d
    from periodos p
  ),
  dias as (
    select d::date as dia from generate_series(p_inicio, p_fim, interval '1 day') d
  ),
  serie as (
    select jsonb_agg(jsonb_build_object(
      'dia', dias.dia,
      'anuncio',  (select count(*) from ld where ld.dia = dias.dia and origem = 'anuncio'),
      'organico', (select count(*) from ld where ld.dia = dias.dia and origem = 'organico'),
      'manual',   (select count(*) from ld where ld.dia = dias.dia and origem = 'manual'),
      'vendas',   (select count(*) from vd where vd.dia = dias.dia),
      'faturamento', (select coalesce(sum(valor), 0) from vd where vd.dia = dias.dia),
      'gasto',    (select coalesce(sum(gasto), 0) from md where md.data = dias.dia)
    ) order by dias.dia) as s
    from dias
  ),
  -- Funil: etapas de entrada, andamento e venda, na ordem. Cada lead conta em todas as etapas
  -- até a mais avançada que já alcançou (pelo histórico, pela etapa atual ou por ter comprado).
  fe as (
    select id, nome, tipo,
           row_number() over (order by case tipo when 'entrada' then 0 when 'andamento' then 1 else 2 end, ordem, criado_em) as k
    from etapas where cliente_id = p_cliente and tipo in ('entrada', 'andamento', 'venda')
  ),
  alc as (
    select ld.id,
           greatest(
             coalesce((select max(fe.k) from fe
                       where fe.id = ld.etapa_id
                          or fe.id in (select h.para_etapa from etapa_historico h where h.lead_id = ld.id)), 1),
             case when exists (select 1 from vendas v where v.lead_id = ld.id)
                  then (select max(k) from fe where tipo = 'venda') else 1 end
           ) as k
    from ld where ld.dia between p_inicio and p_fim
  ),
  funil as (
    select jsonb_agg(jsonb_build_object('id', fe.id, 'nome', fe.nome, 'tipo', fe.tipo,
                                        'leads', (select count(*) from alc where alc.k >= fe.k)) order by fe.k) as f
    from fe
  )
  select jsonb_build_object(
    'atual',    (select d from resumo where p = 'atual'),
    'anterior', (select d from resumo where p = 'anterior'),
    'serie',    coalesce((select s from serie), '[]'::jsonb),
    'funil',    coalesce((select f from funil), '[]'::jsonb),
    'dias',     (select dias from per)
  )
$$;
grant execute on function public.painel(uuid, date, date) to authenticated;
