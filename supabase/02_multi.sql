-- Parte 2: área do cliente (todas as rifas de um telefone)
create or replace function public.meus_todos(p_whats text)
returns table(campanha_id uuid, titulo text, imagem text, total int, status_campanha text, resultado jsonb, pedido uuid, status text, numeros int[], valor numeric, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.titulo, c.imagem_url, c.total, c.status, c.resultado, p.id, p.status, p.numeros, p.valor, p.created_at
    from pedidos p join campanhas c on c.id = p.campanha_id
   where p.whats = regexp_replace(coalesce(p_whats,''), '\D', '', 'g')
     and length(regexp_replace(coalesce(p_whats,''), '\D', '', 'g')) >= 10
     and p.status in ('aguardando','pago') and c.status <> 'rascunho'
   order by p.created_at desc limit 200;
$$;
revoke execute on function public.meus_todos(text) from public;
grant execute on function public.meus_todos(text) to anon, authenticated;

-- progresso de cada campanha para a vitrine (sem expor dados pessoais)
create or replace function public.progresso()
returns table(campanha_id uuid, vendidos bigint) language sql stable security definer set search_path = public as $$
  select n.campanha_id, count(*) from numeros n join campanhas c on c.id = n.campanha_id
   where c.status <> 'rascunho' group by n.campanha_id;
$$;
revoke execute on function public.progresso() from public;
grant execute on function public.progresso() to anon, authenticated;
