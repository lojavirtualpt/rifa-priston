-- Parte 4: data limite de vendas por campanha
alter table public.campanhas add column if not exists data_limite timestamptz;

-- reservas só até a data limite (se definida)
create or replace function public.bloqueia_apos_limite() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim timestamptz;
begin
  select data_limite into lim from campanhas where id = new.campanha_id;
  if lim is not null and now() > lim then raise exception 'As vendas desta rifa foram encerradas'; end if;
  return new;
end $$;
drop trigger if exists trg_limite on public.pedidos;
create trigger trg_limite before insert on public.pedidos for each row execute function public.bloqueia_apos_limite();
select 'ok' as resultado;
