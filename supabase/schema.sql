-- =====================================================================
-- RIFA PRISTON — banco protegido (rodar no Supabase > SQL Editor)
-- Princípio: o navegador NUNCA escreve direto nas tabelas.
--  * Visitante: só lê a campanha e o mapa de números; reserva via função.
--  * Admin: precisa estar logado COM 2FA (aal2) e estar na tabela admins.
-- =====================================================================

create extension if not exists pgcrypto;

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.campanhas (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (length(titulo) between 3 and 120),
  descricao text default '' check (length(descricao) <= 4000),
  imagem_url text default '',
  valor_mercado numeric(12,2) default 0,
  preco numeric(10,2) not null check (preco > 0),
  total int not null check (total in (100,1000,10000,100000)),
  concurso text default '',
  data_sorteio text default '',
  pacotes int[] default '{10,25,50,100}',
  cotas jsonb default '[]',           -- [{"n":77,"premio":"1kk de gold"}]
  status text not null default 'rascunho' check (status in ('rascunho','ativa','encerrada')),
  resultado jsonb,
  created_at timestamptz default now()
);

create table if not exists public.pedidos (
  id uuid primary key default gen_random_uuid(),
  campanha_id uuid not null references public.campanhas(id) on delete cascade,
  nome text not null,
  whats text not null,
  numeros int[] not null,
  valor numeric(12,2) not null,
  status text not null default 'aguardando' check (status in ('aguardando','pago','expirado','cancelado')),
  expira_em timestamptz not null,
  created_at timestamptz default now()
);
create index if not exists pedidos_whats on public.pedidos(campanha_id, whats);

create table if not exists public.numeros (
  campanha_id uuid not null references public.campanhas(id) on delete cascade,
  numero int not null,
  pedido_id uuid not null references public.pedidos(id) on delete cascade,
  pago boolean not null default false,
  primary key (campanha_id, numero)
);

alter table public.campanhas add column if not exists galeria text[] default '{}';

-- Aparência e textos do site (linha única id=1), editável só pelo admin
create table if not exists public.site (
  id int primary key default 1 check (id = 1),
  dados jsonb not null default '{}'
);
insert into public.site(id) values (1) on conflict do nothing;

-- Log de tudo que o admin altera (auditoria)
create table if not exists public.auditoria (
  id bigserial primary key,
  quando timestamptz default now(),
  usuario uuid default auth.uid(),
  tabela text, acao text, dados jsonb
);

-- ---------- quem é admin (exige 2FA ativo na sessão) ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from admins where user_id = auth.uid())
     and coalesce(auth.jwt()->>'aal','') = 'aal2';
$$;

-- ---------- RLS ----------
alter table public.admins    enable row level security;
alter table public.campanhas enable row level security;
alter table public.pedidos   enable row level security;
alter table public.numeros   enable row level security;
alter table public.auditoria enable row level security;
alter table public.site      enable row level security;
drop policy if exists site_ler on public.site;
create policy site_ler on public.site for select using (true);
drop policy if exists site_admin on public.site;
create policy site_admin on public.site for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists camp_ler on public.campanhas;
create policy camp_ler on public.campanhas for select using (status <> 'rascunho' or public.is_admin());
drop policy if exists camp_admin on public.campanhas;
create policy camp_admin on public.campanhas for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists ped_admin on public.pedidos;
create policy ped_admin on public.pedidos for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists num_ler on public.numeros;
create policy num_ler on public.numeros for select using (true);   -- só número/pago, sem dados pessoais
drop policy if exists num_admin on public.numeros;
create policy num_admin on public.numeros for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists adm_self on public.admins;
create policy adm_self on public.admins for select using (user_id = auth.uid());
drop policy if exists aud_admin on public.auditoria;
create policy aud_admin on public.auditoria for select using (public.is_admin());

-- auditoria automática
create or replace function public.audita() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into auditoria(tabela, acao, dados) values (tg_table_name, tg_op, to_jsonb(coalesce(new, old)));
  return coalesce(new, old);
end $$;
drop trigger if exists aud_camp on public.campanhas;
create trigger aud_camp after insert or update or delete on public.campanhas for each row execute function public.audita();

-- ---------- funções públicas (únicas portas de entrada do visitante) ----------
create or replace function public.reservar(p_campanha uuid, p_qtd int, p_nome text, p_whats text)
returns json language plpgsql security definer set search_path = public as $$
declare c campanhas; v_pedido uuid; v_nums int[];
begin
  p_nome  := left(regexp_replace(trim(coalesce(p_nome,'')), '[<>"''&]', '', 'g'), 40);
  p_whats := regexp_replace(coalesce(p_whats,''), '\D', '', 'g');
  if p_qtd is null or p_qtd < 1 or p_qtd > 500 then raise exception 'Quantidade inválida'; end if;
  if length(p_nome) < 2 or length(p_whats) not between 10 and 13 then raise exception 'Dados inválidos'; end if;

  select * into c from campanhas where id = p_campanha and status = 'ativa' for update;
  if not found then raise exception 'Campanha indisponível'; end if;

  -- libera reservas vencidas
  delete from numeros n using pedidos p
   where n.pedido_id = p.id and p.campanha_id = p_campanha and p.status = 'aguardando' and p.expira_em < now();
  update pedidos set status = 'expirado'
   where campanha_id = p_campanha and status = 'aguardando' and expira_em < now();

  -- anti-abuso: no máximo 3 reservas pendentes por telefone
  if (select count(*) from pedidos where campanha_id = p_campanha and whats = p_whats and status = 'aguardando') >= 3 then
    raise exception 'Você já tem reservas aguardando pagamento';
  end if;

  select array_agg(g) into v_nums from (
    select g from generate_series(0, c.total - 1) g
     where not exists (select 1 from numeros where campanha_id = p_campanha and numero = g)
     order by random() limit p_qtd) t;
  if coalesce(array_length(v_nums,1),0) < p_qtd then raise exception 'Números insuficientes'; end if;

  insert into pedidos(campanha_id, nome, whats, numeros, valor, expira_em)
  values (p_campanha, p_nome, p_whats, v_nums, p_qtd * c.preco, now() + interval '15 minutes')
  returning id into v_pedido;
  insert into numeros(campanha_id, numero, pedido_id) select p_campanha, unnest(v_nums), v_pedido;

  return json_build_object('pedido', v_pedido, 'numeros', v_nums, 'valor', p_qtd * c.preco);
end $$;

create or replace function public.meus_numeros(p_campanha uuid, p_whats text)
returns table(id uuid, status text, numeros int[]) language sql stable security definer set search_path = public as $$
  select id, status, numeros from pedidos
   where campanha_id = p_campanha and whats = regexp_replace(p_whats, '\D', '', 'g') and status in ('aguardando','pago')
   order by created_at;
$$;

create or replace function public.ranking(p_campanha uuid)
returns table(nome text, qtd bigint) language sql stable security definer set search_path = public as $$
  select split_part(nome, ' ', 1), sum(array_length(numeros,1)) from pedidos
   where campanha_id = p_campanha and status = 'pago'
   group by whats, split_part(nome, ' ', 1) order by 2 desc limit 3;
$$;

-- admin: confirmar pagamento manualmente (em produção o webhook do Pix faz isso)
create or replace function public.confirmar_pedido(p_pedido uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  update pedidos set status = 'pago' where id = p_pedido;
  update numeros set pago = true where pedido_id = p_pedido;
  insert into auditoria(tabela, acao, dados) values ('pedidos', 'CONFIRMAR', json_build_object('pedido', p_pedido));
end $$;

-- permissões: anônimo só executa as 3 funções públicas
revoke all on all tables in schema public from anon;
grant select on public.campanhas, public.numeros, public.site to anon;
-- logado: as permissões abaixo só valem na prática para admin com 2FA (RLS filtra o resto)
grant select, insert, update, delete on public.campanhas, public.pedidos, public.numeros to authenticated;
grant select, update on public.site to authenticated;
grant select on public.admins, public.auditoria to authenticated;
revoke execute on all functions in schema public from anon, public;
grant execute on function public.reservar(uuid,int,text,text), public.meus_numeros(uuid,text), public.ranking(uuid), public.is_admin() to anon, authenticated;
grant execute on function public.confirmar_pedido(uuid) to authenticated;

-- ---------- Storage: fotos dos personagens ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('personagens', 'personagens', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists foto_admin on storage.objects;
create policy foto_admin on storage.objects for all to authenticated
  using (bucket_id = 'personagens' and public.is_admin())
  with check (bucket_id = 'personagens' and public.is_admin());

-- ---------- ÚLTIMO PASSO (depois de criar seu usuário em Authentication > Users) ----------
-- insert into public.admins(user_id) select id from auth.users where email = 'SEU_EMAIL_AQUI';
