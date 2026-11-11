-- Parte 7: permite excluir reservas vencidas mesmo antes da limpeza automática marcá-las como expiradas
create or replace function public.excluir_pedido(p_pedido uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p pedidos;
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  select * into p from pedidos where id = p_pedido;
  if not found then raise exception 'Pedido não encontrado'; end if;
  if not (p.status in ('cancelado','expirado') or (p.status = 'aguardando' and p.expira_em < now())) then
    raise exception 'Cancele o pedido antes de excluir';
  end if;
  insert into auditoria(tabela, acao, dados) values ('pedidos', 'EXCLUIR', to_jsonb(p));
  delete from numeros where pedido_id = p_pedido;
  delete from pedidos where id = p_pedido;
end $$;
revoke execute on function public.excluir_pedido(uuid) from public, anon;
grant execute on function public.excluir_pedido(uuid) to authenticated;
select 'ok' as resultado;
