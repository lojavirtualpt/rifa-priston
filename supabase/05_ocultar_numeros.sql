-- Parte 5: números só são revelados ao cliente depois do pagamento
drop function if exists public.meus_todos(text);
create function public.meus_todos(p_whats text)
returns table(campanha_id uuid, titulo text, imagem text, total int, status_campanha text, resultado jsonb, pedido uuid, status text, numeros int[], qtd int, valor numeric, created_at timestamptz, checkout_url text, expira_em timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.titulo, c.imagem_url, c.total, c.status, c.resultado, p.id, p.status,
         case when p.status = 'pago' then p.numeros else '{}'::int[] end,
         array_length(p.numeros,1), p.valor, p.created_at, p.checkout_url, p.expira_em
    from pedidos p join campanhas c on c.id = p.campanha_id
   where p.whats = regexp_replace(coalesce(p_whats,''), '\D', '', 'g')
     and length(regexp_replace(coalesce(p_whats,''), '\D', '', 'g')) >= 10
     and p.status in ('aguardando','pago','reembolsar') and c.status <> 'rascunho'
   order by p.created_at desc limit 200;
$$;
revoke execute on function public.meus_todos(text) from public;
grant execute on function public.meus_todos(text) to anon, authenticated;

-- a reserva devolve só a quantidade (sem os números) até o pagamento
create or replace function public.reservar_publico(p_campanha uuid, p_qtd int, p_nome text, p_whats text)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  r := public.reservar(p_campanha, p_qtd, p_nome, p_whats);
  return json_build_object('pedido', r->'pedido', 'qtd', p_qtd, 'valor', r->'valor');
end $$;
revoke execute on function public.reservar_publico(uuid,int,text,text) from public;
grant execute on function public.reservar_publico(uuid,int,text,text) to anon, authenticated;
revoke execute on function public.reservar(uuid,int,text,text) from anon, authenticated;
select 'ok' as resultado;
