-- Parte 3: pagamento automático (InfinitePay)
alter table public.pedidos add column if not exists checkout_url text;
alter table public.pedidos add column if not exists transaction_nsu text;
alter table public.pedidos add column if not exists receipt_url text;
alter table public.pedidos add column if not exists metodo text;
alter table public.pedidos drop constraint if exists pedidos_status_check;
alter table public.pedidos add constraint pedidos_status_check
  check (status in ('aguardando','pago','expirado','cancelado','reembolsar'));
create unique index if not exists pedidos_tx on public.pedidos(transaction_nsu) where transaction_nsu is not null;

-- Chamada SOMENTE pela função do servidor (service_role) depois de conferir na InfinitePay
create or replace function public.registrar_pagamento(p_pedido uuid, p_tx text, p_receipt text, p_metodo text)
returns text language plpgsql security definer set search_path = public as $$
declare p pedidos; ocupados int;
begin
  select * into p from pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido inexistente'; end if;
  if p.status in ('pago','reembolsar') then return p.status; end if;

  -- pagou depois de expirar: tenta devolver os mesmos números; se alguém pegou, marca para reembolso
  if p.status in ('expirado','cancelado') then
    select count(*) into ocupados from numeros x
     where x.campanha_id = p.campanha_id and x.numero = any(p.numeros) and x.pedido_id <> p.id;
    if ocupados > 0 then
      update pedidos set status = 'reembolsar', transaction_nsu = p_tx, receipt_url = p_receipt, metodo = p_metodo where id = p.id;
      return 'reembolsar';
    end if;
    insert into numeros(campanha_id, numero, pedido_id)
      select p.campanha_id, unnest(p.numeros), p.id on conflict do nothing;
  end if;

  update pedidos set status = 'pago', transaction_nsu = p_tx, receipt_url = p_receipt, metodo = p_metodo where id = p.id;
  update numeros set pago = true where pedido_id = p.id;
  insert into auditoria(tabela, acao, dados) values ('pedidos', 'PAGO_INFINITEPAY', json_build_object('pedido', p.id, 'tx', p_tx));
  return 'pago';
end $$;
revoke execute on function public.registrar_pagamento(uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.registrar_pagamento(uuid,text,text,text) to service_role;

-- área do cliente passa a devolver o link de pagamento (para retomar)
drop function if exists public.meus_todos(text);
create function public.meus_todos(p_whats text)
returns table(campanha_id uuid, titulo text, imagem text, total int, status_campanha text, resultado jsonb, pedido uuid, status text, numeros int[], valor numeric, created_at timestamptz, checkout_url text, expira_em timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.titulo, c.imagem_url, c.total, c.status, c.resultado, p.id, p.status, p.numeros, p.valor, p.created_at, p.checkout_url, p.expira_em
    from pedidos p join campanhas c on c.id = p.campanha_id
   where p.whats = regexp_replace(coalesce(p_whats,''), '\D', '', 'g')
     and length(regexp_replace(coalesce(p_whats,''), '\D', '', 'g')) >= 10
     and p.status in ('aguardando','pago','reembolsar') and c.status <> 'rascunho'
   order by p.created_at desc limit 200;
$$;
revoke execute on function public.meus_todos(text) from public;
grant execute on function public.meus_todos(text) to anon, authenticated;
