create table public.items (
  id bigint generated always as identity primary key,
  barcode text not null unique,
  name text not null,
  brand text,
  type text,
  category text not null default 'Men' check (category in ('Men','Women','Kids')),
  size text,
  color text,
  price numeric(10,2) not null default 0 check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create sequence public.bill_no_seq start 1001;

create table public.sales (
  id bigint generated always as identity primary key,
  bill_no text not null unique default ('INV-' || nextval('public.bill_no_seq')),
  customer text not null default 'Walk-in Customer',
  phone text,
  subtotal numeric(10,2) not null,
  discount numeric(10,2) not null default 0,
  total numeric(10,2) not null,
  pay_mode text not null check (pay_mode in ('Cash','UPI','Udhaar')),
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.sale_items (
  id bigint generated always as identity primary key,
  sale_id bigint not null references public.sales(id) on delete cascade,
  item_id bigint references public.items(id) on delete set null,
  name text not null,
  size text,
  price numeric(10,2) not null,
  qty integer not null check (qty > 0)
);
create index on public.sale_items(sale_id);
create index on public.sale_items(item_id);
create index on public.sales(created_at desc);

create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;
create trigger items_touch before update on public.items
for each row execute function public.touch_updated_at();

-- Atomic checkout: locks rows, checks stock, writes bill, decrements stock.
-- (Replaced in 0002 with customer + udhaar support.)
create or replace function public.checkout(p_customer text, p_phone text, p_discount numeric, p_pay_mode text, p_lines jsonb)
returns public.sales
language plpgsql security invoker set search_path = '' as $$
declare
  v_line jsonb; v_item public.items; v_sub numeric := 0; v_sale public.sales;
begin
  if jsonb_array_length(coalesce(p_lines,'[]'::jsonb)) = 0 then raise exception 'Cart is empty'; end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    select * into v_item from public.items where id = (v_line->>'item_id')::bigint for update;
    if not found then raise exception 'Item % not found', v_line->>'item_id'; end if;
    if v_item.stock < (v_line->>'qty')::int then
      raise exception 'Only % pcs left of % (%)', v_item.stock, v_item.name, v_item.size;
    end if;
    v_sub := v_sub + v_item.price * (v_line->>'qty')::int;
  end loop;

  insert into public.sales(customer, phone, subtotal, discount, total, pay_mode)
  values (coalesce(nullif(trim(p_customer),''),'Walk-in Customer'), nullif(trim(p_phone),''), v_sub,
          greatest(coalesce(p_discount,0),0), greatest(v_sub - coalesce(p_discount,0), 0), p_pay_mode)
  returning * into v_sale;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    update public.items set stock = stock - (v_line->>'qty')::int
    where id = (v_line->>'item_id')::bigint returning * into v_item;
    insert into public.sale_items(sale_id, item_id, name, size, price, qty)
    values (v_sale.id, v_item.id, v_item.name, v_item.size, v_item.price, (v_line->>'qty')::int);
  end loop;
  return v_sale;
end $$;

alter table public.items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;

-- Base rules for signed-in users; 0002 adds restrictive staff-only rules on top.
create policy "staff read items" on public.items for select to authenticated using (true);
create policy "staff add items" on public.items for insert to authenticated with check (true);
create policy "staff edit items" on public.items for update to authenticated using (true) with check (true);
create policy "staff delete items" on public.items for delete to authenticated using (true);
create policy "staff read sales" on public.sales for select to authenticated using (true);
create policy "staff add sales" on public.sales for insert to authenticated with check (true);
create policy "staff read sale items" on public.sale_items for select to authenticated using (true);
create policy "staff add sale items" on public.sale_items for insert to authenticated with check (true);

revoke all on function public.checkout(text,text,numeric,text,jsonb) from public, anon;
grant execute on function public.checkout(text,text,numeric,text,jsonb) to authenticated;
grant usage on sequence public.bill_no_seq to authenticated;
