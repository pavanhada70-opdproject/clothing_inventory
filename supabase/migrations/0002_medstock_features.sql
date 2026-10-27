-- Staff allow-list with roles (like MedStock's store_members)
create table public.staff (
  email text primary key check (email = lower(email)),
  role text not null default 'staff' check (role in ('owner','staff')),
  added_at timestamptz not null default now()
);
alter table public.staff enable row level security;
insert into public.staff(email, role) values ('pavanhada70@gmail.com', 'owner');

create or replace function public.staff_role() returns text
language sql stable security definer set search_path = '' as $$
  select role from public.staff where email = lower(coalesce(auth.jwt()->>'email',''));
$$;
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.staff_role() is not null;
$$;
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.staff_role() = 'owner';
$$;
revoke all on function public.staff_role() from public, anon;
revoke all on function public.is_staff() from public, anon;
revoke all on function public.is_owner() from public, anon;
grant execute on function public.staff_role(), public.is_staff(), public.is_owner() to authenticated;

create policy staff_select on public.staff for select to authenticated using ((select public.is_staff()));
create policy staff_write on public.staff for all to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));

-- Tighten existing tables: only listed staff, deletes owner-only (restrictive = AND with existing rules)
create policy items_staff_only on public.items as restrictive for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
create policy items_owner_delete on public.items as restrictive for delete to authenticated
  using ((select public.is_owner()));
create policy sales_staff_only on public.sales as restrictive for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
create policy sale_items_staff_only on public.sale_items as restrictive for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

-- Reorder level per item (low-stock alerts) and dates for slow-moving stock
alter table public.items add column reorder_level integer not null default 0 check (reorder_level >= 0);
alter table public.items add column last_sold_at timestamptz;
alter table public.items add column last_received_at timestamptz default now();

-- Append-only stock log (like MedStock's stock_movements)
create table public.stock_movements (
  id bigint generated always as identity primary key,
  item_id bigint references public.items(id) on delete set null,
  item_name text,
  change integer not null,
  stock_after integer not null,
  reason text not null,
  by_email text default lower(auth.jwt()->>'email'),
  created_at timestamptz not null default now()
);
create index on public.stock_movements(item_id, created_at desc);
create index on public.stock_movements(created_at desc);
alter table public.stock_movements enable row level security;
create policy movements_select on public.stock_movements for select to authenticated using ((select public.is_staff()));
create policy movements_insert on public.stock_movements for insert to authenticated with check ((select public.is_staff()));

create or replace function public.log_stock_change() returns trigger
language plpgsql set search_path = '' as $$
declare v_reason text := coalesce(nullif(current_setting('app.stock_reason', true), ''), 'Manual adjustment');
begin
  if tg_op = 'INSERT' then
    insert into public.stock_movements(item_id, item_name, change, stock_after, reason)
    values (new.id, new.name || ' (' || coalesce(new.size,'') || ')', new.stock, new.stock,
            coalesce(nullif(current_setting('app.stock_reason', true), ''), 'New item'));
  elsif new.stock is distinct from old.stock then
    insert into public.stock_movements(item_id, item_name, change, stock_after, reason)
    values (new.id, new.name || ' (' || coalesce(new.size,'') || ')', new.stock - old.stock, new.stock, v_reason);
  end if;
  return new;
end $$;
create trigger items_log_stock after insert or update of stock on public.items
for each row execute function public.log_stock_change();

-- Customers (like MedStock's OPD patients) with udhaar (credit) tracking
create table public.customers (
  id bigint generated always as identity primary key,
  name text not null,
  phone text unique,
  created_at timestamptz not null default now()
);
alter table public.customers enable row level security;
create policy customers_rw on public.customers for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
alter table public.sales add column customer_id bigint references public.customers(id);
create index on public.sales(customer_id);

create table public.udhaar_payments (
  id bigint generated always as identity primary key,
  customer_id bigint not null references public.customers(id),
  amount numeric(10,2) not null check (amount > 0),
  mode text not null default 'Cash' check (mode in ('Cash','UPI')),
  note text,
  by_email text default lower(auth.jwt()->>'email'),
  created_at timestamptz not null default now()
);
create index on public.udhaar_payments(customer_id);
alter table public.udhaar_payments enable row level security;
create policy udhaar_select on public.udhaar_payments for select to authenticated using ((select public.is_staff()));
create policy udhaar_insert on public.udhaar_payments for insert to authenticated with check ((select public.is_staff()));

create view public.customer_balances with (security_invoker = true) as
select c.id, c.name, c.phone,
  coalesce((select sum(s.total) from public.sales s where s.customer_id = c.id and s.pay_mode = 'Udhaar'), 0) as udhaar_given,
  coalesce((select sum(p.amount) from public.udhaar_payments p where p.customer_id = c.id), 0) as udhaar_paid,
  (select count(*) from public.sales s where s.customer_id = c.id) as bills,
  (select max(s.created_at) from public.sales s where s.customer_id = c.id) as last_visit
from public.customers c;

-- Purchase bills from suppliers (like MedStock's distributor invoices)
create table public.purchases (
  id bigint generated always as identity primary key,
  supplier text not null,
  bill_no text,
  bill_date date default current_date,
  photo_path text,
  status text not null default 'draft' check (status in ('draft','committed')),
  total_pcs integer not null default 0,
  by_email text default lower(auth.jwt()->>'email'),
  created_at timestamptz not null default now(),
  committed_at timestamptz
);
create table public.purchase_lines (
  id bigint generated always as identity primary key,
  purchase_id bigint not null references public.purchases(id) on delete cascade,
  item_id bigint references public.items(id) on delete set null,
  brand text not null,
  type text not null,
  category text not null default 'Men' check (category in ('Men','Women','Kids')),
  size text not null,
  color text,
  price numeric(10,2) not null check (price > 0),
  qty integer not null check (qty > 0),
  barcode text
);
create index on public.purchase_lines(purchase_id);
create index on public.purchase_lines(item_id);
alter table public.purchases enable row level security;
alter table public.purchase_lines enable row level security;
create policy purchases_select on public.purchases for select to authenticated using ((select public.is_staff()));
create policy purchases_insert on public.purchases for insert to authenticated with check ((select public.is_staff()));
create policy purchases_update on public.purchases for update to authenticated
  using ((select public.is_staff()) and status = 'draft') with check ((select public.is_staff()));
create policy purchases_delete on public.purchases for delete to authenticated
  using ((select public.is_owner()) and status = 'draft');
create policy plines_select on public.purchase_lines for select to authenticated using ((select public.is_staff()));
create policy plines_write on public.purchase_lines for all to authenticated
  using ((select public.is_staff()) and exists (select 1 from public.purchases p where p.id = purchase_id and p.status = 'draft'))
  with check ((select public.is_staff()) and exists (select 1 from public.purchases p where p.id = purchase_id and p.status = 'draft'));

-- Commit a purchase bill: matches existing item by barcode or brand+type+size+category+color, else creates it; adds stock atomically
create or replace function public.commit_purchase(p_purchase bigint)
returns public.purchases
language plpgsql security invoker set search_path = '' as $$
declare v_p public.purchases; v_l public.purchase_lines; v_item public.items; v_pcs int := 0;
begin
  select * into v_p from public.purchases where id = p_purchase for update;
  if not found then raise exception 'Purchase bill not found'; end if;
  if v_p.status <> 'draft' then raise exception 'This bill is already added to stock'; end if;
  perform set_config('app.stock_reason', 'Purchase: ' || v_p.supplier || coalesce(' #' || v_p.bill_no, ''), true);

  for v_l in select * from public.purchase_lines where purchase_id = p_purchase order by id loop
    v_item := null;
    if nullif(trim(v_l.barcode),'') is not null then
      select * into v_item from public.items where barcode = trim(v_l.barcode) for update;
    end if;
    if v_item.id is null then
      select * into v_item from public.items
      where upper(brand) = upper(trim(v_l.brand)) and type = v_l.type and upper(size) = upper(trim(v_l.size))
        and category = v_l.category and coalesce(upper(color),'') = coalesce(upper(trim(v_l.color)),'')
      order by id limit 1 for update;
    end if;
    if v_item.id is null then
      insert into public.items(barcode, name, brand, type, category, size, color, price, stock)
      values (coalesce(nullif(trim(v_l.barcode),''), 'SKU-P' || p_purchase || '-' || v_l.id),
              upper(trim(v_l.brand)) || ' ' || v_l.type, upper(trim(v_l.brand)), v_l.type, v_l.category,
              upper(trim(v_l.size)), nullif(upper(trim(v_l.color)),''), v_l.price, v_l.qty)
      returning * into v_item;
    else
      update public.items set stock = stock + v_l.qty, price = v_l.price, last_received_at = now()
      where id = v_item.id returning * into v_item;
    end if;
    update public.purchase_lines set item_id = v_item.id where id = v_l.id;
    v_pcs := v_pcs + v_l.qty;
  end loop;

  if v_pcs = 0 then raise exception 'Add at least one line before adding to stock'; end if;
  update public.purchases set status = 'committed', committed_at = now(), total_pcs = v_pcs
  where id = p_purchase returning * into v_p;
  return v_p;
end $$;
revoke all on function public.commit_purchase(bigint) from public, anon;
grant execute on function public.commit_purchase(bigint) to authenticated;

-- Checkout now links customers, requires a name+phone for Udhaar, logs stock movement and last sold date
drop function public.checkout(text,text,numeric,text,jsonb);
create function public.checkout(p_customer text, p_phone text, p_discount numeric, p_pay_mode text, p_lines jsonb)
returns public.sales
language plpgsql security invoker set search_path = '' as $$
declare
  v_line jsonb; v_item public.items; v_sub numeric := 0; v_sale public.sales; v_cust bigint;
  v_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  v_name text := nullif(trim(coalesce(p_customer,'')), '');
begin
  if jsonb_array_length(coalesce(p_lines,'[]'::jsonb)) = 0 then raise exception 'Cart is empty'; end if;
  if p_pay_mode = 'Udhaar' and (v_name is null or v_phone is null) then
    raise exception 'Udhaar needs the customer name and mobile number';
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    select * into v_item from public.items where id = (v_line->>'item_id')::bigint for update;
    if not found then raise exception 'Item % not found', v_line->>'item_id'; end if;
    if v_item.stock < (v_line->>'qty')::int then
      raise exception 'Only % pcs left of % (%)', v_item.stock, v_item.name, v_item.size;
    end if;
    v_sub := v_sub + v_item.price * (v_line->>'qty')::int;
  end loop;

  if v_phone is not null then
    v_phone := right(v_phone, 10);
    insert into public.customers(name, phone) values (coalesce(v_name, 'Customer'), v_phone)
    on conflict (phone) do update set name = coalesce(v_name, public.customers.name)
    returning id into v_cust;
  end if;

  insert into public.sales(customer, phone, customer_id, subtotal, discount, total, pay_mode)
  values (coalesce(v_name,'Walk-in Customer'), v_phone, v_cust, v_sub,
          greatest(coalesce(p_discount,0),0), greatest(v_sub - coalesce(p_discount,0), 0), p_pay_mode)
  returning * into v_sale;
  perform set_config('app.stock_reason', 'Sale ' || v_sale.bill_no, true);

  for v_line in select * from jsonb_array_elements(p_lines) loop
    update public.items set stock = stock - (v_line->>'qty')::int, last_sold_at = now()
    where id = (v_line->>'item_id')::bigint returning * into v_item;
    insert into public.sale_items(sale_id, item_id, name, size, price, qty)
    values (v_sale.id, v_item.id, v_item.name, v_item.size, v_item.price, (v_line->>'qty')::int);
  end loop;
  return v_sale;
end $$;
revoke all on function public.checkout(text,text,numeric,text,jsonb) from public, anon;
grant execute on function public.checkout(text,text,numeric,text,jsonb) to authenticated;

-- Private bucket for supplier bill photos
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bills', 'bills', false, 10485760, array['image/jpeg','image/png','image/webp','application/pdf']);
create policy bills_select on storage.objects for select to authenticated
  using (bucket_id = 'bills' and (select public.is_staff()));
create policy bills_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'bills' and (select public.is_staff()));

-- Live updates across counters
alter publication supabase_realtime add table public.items, public.sales;
