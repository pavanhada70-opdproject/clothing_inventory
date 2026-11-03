-- Edit and delete past bills (owner only). Reprint needs no database change.
-- Run once in the Supabase SQL editor of project "clothing-inventory".
--
-- Stock: deleting a bill puts its pieces back in stock; editing a bill only moves the difference.
-- Udhaar: balances are worked out from the bills (customer_balances view), so they follow automatically.
-- Every stock change is written to the stock log as "Bill INV-xxxx edited" or "Bill INV-xxxx deleted".

-- Owners may change and remove bills (staff keep read + add only)
create policy sales_owner_update on public.sales for update to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));
create policy sales_owner_delete on public.sales for delete to authenticated
  using ((select public.is_owner()));
create policy sale_items_owner_delete on public.sale_items for delete to authenticated
  using ((select public.is_owner()));

-- When a bill was last changed
alter table public.sales add column if not exists edited_at timestamptz;

-- Delete a bill and return its pieces to stock
create or replace function public.delete_bill(p_sale bigint)
returns void
language plpgsql security invoker set search_path = '' as $$
declare v_sale public.sales; v_line record;
begin
  if not public.is_owner() then raise exception 'Only the owner can delete bills'; end if;
  select * into v_sale from public.sales where id = p_sale for update;
  if not found then raise exception 'Bill not found'; end if;
  perform set_config('app.stock_reason', 'Bill ' || v_sale.bill_no || ' deleted', true);
  for v_line in
    select item_id, sum(qty)::int as qty from public.sale_items
    where sale_id = p_sale and item_id is not null group by item_id order by item_id
  loop
    update public.items set stock = stock + v_line.qty where id = v_line.item_id;
  end loop;
  delete from public.sales where id = p_sale;  -- sale_items go with it (on delete cascade)
end $$;
revoke all on function public.delete_bill(bigint) from public, anon;
grant execute on function public.delete_bill(bigint) to authenticated;

-- Edit a bill: new items, quantities, discount, customer and payment. Bill number and date stay the same.
-- Items already on the bill keep the price they were sold at; newly added items take today's price.
create or replace function public.edit_bill(p_sale bigint, p_customer text, p_phone text, p_discount numeric,
                                            p_pay_mode text, p_lines jsonb,
                                            p_cash numeric default null, p_upi numeric default null)
returns public.sales
language plpgsql security invoker set search_path = '' as $$
declare
  v_sale public.sales; v_line jsonb; v_item public.items; v_net record; v_price numeric;
  v_sub numeric := 0; v_total numeric; v_cust bigint;
  v_cash numeric := 0; v_upi numeric := 0; v_udhaar numeric := 0; v_mode text := p_pay_mode;
  v_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  v_name text := nullif(trim(coalesce(p_customer,'')), '');
begin
  if not public.is_owner() then raise exception 'Only the owner can edit bills'; end if;
  select * into v_sale from public.sales where id = p_sale for update;
  if not found then raise exception 'Bill not found'; end if;
  if exists (select 1 from public.sale_items where sale_id = p_sale and item_id is null) then
    raise exception 'An item on this bill was removed from stock, so the bill cannot be edited. Delete it and make a new bill instead.';
  end if;
  if jsonb_array_length(coalesce(p_lines,'[]'::jsonb)) = 0 then
    raise exception 'A bill needs at least one item. To cancel the whole bill, delete it.';
  end if;
  if v_mode not in ('Cash','UPI','Udhaar','Split') then raise exception 'Unknown payment mode %', v_mode; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l where coalesce((l->>'qty')::int, 0) <= 0) then
    raise exception 'Quantities must be 1 or more';
  end if;

  -- Old and new quantities per item, and the stock difference
  create temp table if not exists pg_temp.bill_edit(item_id bigint primary key, old_qty int, new_qty int, old_price numeric) on commit drop;
  truncate pg_temp.bill_edit;
  insert into pg_temp.bill_edit(item_id, old_qty, new_qty, old_price)
  select item_id, sum(qty)::int, 0, max(price) from public.sale_items where sale_id = p_sale group by item_id;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into pg_temp.bill_edit(item_id, old_qty, new_qty) values ((v_line->>'item_id')::bigint, 0, (v_line->>'qty')::int)
    on conflict (item_id) do update set new_qty = pg_temp.bill_edit.new_qty + excluded.new_qty;
  end loop;

  -- Lock items and check there is enough stock for anything added
  for v_net in select * from pg_temp.bill_edit order by item_id loop
    select * into v_item from public.items where id = v_net.item_id for update;
    if not found then raise exception 'Item % not found', v_net.item_id; end if;
    if v_net.new_qty > v_net.old_qty and v_item.stock < v_net.new_qty - v_net.old_qty then
      raise exception 'Only % more pcs left of % (%)', v_item.stock, v_item.name, v_item.size;
    end if;
    if v_net.new_qty > 0 then
      v_sub := v_sub + coalesce(v_net.old_price, v_item.price) * v_net.new_qty;
    end if;
  end loop;
  v_total := greatest(v_sub - greatest(coalesce(p_discount,0),0), 0);

  -- Payment split, same rules as checkout
  if v_mode = 'Cash' then v_cash := v_total;
  elsif v_mode = 'UPI' then v_upi := v_total;
  elsif v_mode = 'Udhaar' then v_udhaar := v_total;
  else
    v_cash := round(coalesce(p_cash,0), 2);
    v_upi := round(coalesce(p_upi,0), 2);
    if v_cash < 0 or v_upi < 0 then raise exception 'Payment amounts cannot be negative'; end if;
    if v_cash + v_upi > v_total then
      raise exception 'Cash + UPI (₹%) is more than the bill total (₹%)', v_cash + v_upi, v_total;
    end if;
    v_udhaar := v_total - v_cash - v_upi;
    if v_udhaar = 0 and v_upi = 0 then v_mode := 'Cash';
    elsif v_udhaar = 0 and v_cash = 0 then v_mode := 'UPI';
    elsif v_cash = 0 and v_upi = 0 then v_mode := 'Udhaar';
    end if;
  end if;

  if v_udhaar > 0 and (v_name is null or v_phone is null) then
    raise exception 'Udhaar needs the customer name and mobile number';
  end if;

  if v_phone is not null then
    v_phone := right(v_phone, 10);
    insert into public.customers(name, phone) values (coalesce(v_name, 'Customer'), v_phone)
    on conflict (phone) do update set name = coalesce(v_name, public.customers.name)
    returning id into v_cust;
  end if;

  -- Move only the difference in stock
  perform set_config('app.stock_reason', 'Bill ' || v_sale.bill_no || ' edited', true);
  for v_net in select * from pg_temp.bill_edit where new_qty <> old_qty order by item_id loop
    update public.items set stock = stock + v_net.old_qty - v_net.new_qty,
      last_sold_at = case when v_net.new_qty > v_net.old_qty then now() else last_sold_at end
    where id = v_net.item_id;
  end loop;

  -- Rewrite the bill lines
  delete from public.sale_items where sale_id = p_sale;
  insert into public.sale_items(sale_id, item_id, name, size, price, qty)
  select p_sale, i.id, i.name, i.size, coalesce(e.old_price, i.price), e.new_qty
  from pg_temp.bill_edit e join public.items i on i.id = e.item_id
  where e.new_qty > 0 order by i.id;

  update public.sales set
    customer = coalesce(v_name, 'Walk-in Customer'), phone = v_phone, customer_id = v_cust,
    subtotal = v_sub, discount = greatest(coalesce(p_discount,0),0), total = v_total,
    pay_mode = v_mode, paid_cash = v_cash, paid_upi = v_upi, udhaar = v_udhaar, edited_at = now()
  where id = p_sale
  returning * into v_sale;
  return v_sale;
end $$;
revoke all on function public.edit_bill(bigint,text,text,numeric,text,jsonb,numeric,numeric) from public, anon;
grant execute on function public.edit_bill(bigint,text,text,numeric,text,jsonb,numeric,numeric) to authenticated;

-- Other counters hear about deleted bills too
alter table public.sales replica identity full;
