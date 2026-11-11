-- Parte 6: cancelar (libera números, mantém histórico) e excluir (apaga) pedidos — só admin com 2FA
create or replace function public.cancelar_pedido(p_pedido uuid, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  update pedidos set status = 'cancelado' where id = p_pedido;
  if not found then raise exception 'Pedido não encontrado'; end if;
  delete from numeros where pedido_id = p_pedido;
  insert into auditoria(tabela, acao, dados)
    values ('pedidos', 'CANCELAR', json_build_object('pedido', p_pedido, 'motivo', left(coalesce(p_motivo,''), 200)));
end $$;

create or replace function public.excluir_pedido(p_pedido uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p pedidos;
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  select * into p from pedidos where id = p_pedido;
  if not found then raise exception 'Pedido não encontrado'; end if;
  if p.status not in ('cancelado','expirado') then raise exception 'Cancele o pedido antes de excluir'; end if;
  insert into auditoria(tabela, acao, dados) values ('pedidos', 'EXCLUIR', to_jsonb(p));
  delete from numeros where pedido_id = p_pedido;
  delete from pedidos where id = p_pedido;
end $$;

revoke execute on function public.cancelar_pedido(uuid,text), public.excluir_pedido(uuid) from public, anon;
grant execute on function public.cancelar_pedido(uuid,text), public.excluir_pedido(uuid) to authenticated;
select 'ok' as resultado;
