-- Split payments at billing: any mix of Cash, UPI and Udhaar on one bill.
-- Each bill keeps how much came in as cash, as UPI, and how much was left as udhaar.
alter table public.sales add column paid_cash numeric(10,2) not null default 0 check (paid_cash >= 0);
alter table public.sales add column paid_upi numeric(10,2) not null default 0 check (paid_upi >= 0);
alter table public.sales add column udhaar numeric(10,2) not null default 0 check (udhaar >= 0);

-- Older single-mode bills: the whole total went to that mode
update public.sales set
  paid_cash = case when pay_mode = 'Cash' then total else 0 end,
  paid_upi = case when pay_mode = 'UPI' then total else 0 end,
  udhaar = case when pay_mode = 'Udhaar' then total else 0 end;

alter table public.sales drop constraint sales_pay_mode_check;
alter table public.sales add constraint sales_pay_mode_check check (pay_mode in ('Cash','UPI','Udhaar','Split'));
alter table public.sales add constraint sales_payment_adds_up check (paid_cash + paid_upi + udhaar = total);

-- Udhaar owed now comes from the udhaar part of every bill, not only full-udhaar bills
create or replace view public.customer_balances with (security_invoker = true) as
select c.id, c.name, c.phone,
  coalesce((select sum(s.udhaar) from public.sales s where s.customer_id = c.id), 0) as udhaar_given,
  coalesce((select sum(p.amount) from public.udhaar_payments p where p.customer_id = c.id), 0) as udhaar_paid,
  (select count(*) from public.sales s where s.customer_id = c.id) as bills,
  (select max(s.created_at) from public.sales s where s.customer_id = c.id) as last_visit
from public.customers c;

-- Checkout takes the split. p_pay_mode 'Cash' / 'UPI' / 'Udhaar' puts the whole total on that mode (old calls keep working).
-- 'Split' takes p_cash and p_upi; whatever is left of the total becomes udhaar.
drop function public.checkout(text,text,numeric,text,jsonb);
create function public.checkout(p_customer text, p_phone text, p_discount numeric, p_pay_mode text, p_lines jsonb,
                                 p_cash numeric default null, p_upi numeric default null)
returns public.sales
language plpgsql security invoker set search_path = '' as $$
declare
  v_line jsonb; v_item public.items; v_sub numeric := 0; v_total numeric; v_sale public.sales; v_cust bigint;
  v_cash numeric := 0; v_upi numeric := 0; v_udhaar numeric := 0; v_mode text := p_pay_mode;
  v_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  v_name text := nullif(trim(coalesce(p_customer,'')), '');
begin
  if jsonb_array_length(coalesce(p_lines,'[]'::jsonb)) = 0 then raise exception 'Cart is empty'; end if;
  if v_mode not in ('Cash','UPI','Udhaar','Split') then raise exception 'Unknown payment mode %', v_mode; end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    select * into v_item from public.items where id = (v_line->>'item_id')::bigint for update;
    if not found then raise exception 'Item % not found', v_line->>'item_id'; end if;
    if v_item.stock < (v_line->>'qty')::int then
      raise exception 'Only % pcs left of % (%)', v_item.stock, v_item.name, v_item.size;
    end if;
    v_sub := v_sub + v_item.price * (v_line->>'qty')::int;
  end loop;
  v_total := greatest(v_sub - greatest(coalesce(p_discount,0),0), 0);

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
    -- A "split" that is really one mode is saved as that mode
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

  insert into public.sales(customer, phone, customer_id, subtotal, discount, total, pay_mode, paid_cash, paid_upi, udhaar)
  values (coalesce(v_name,'Walk-in Customer'), v_phone, v_cust, v_sub,
          greatest(coalesce(p_discount,0),0), v_total, v_mode, v_cash, v_upi, v_udhaar)
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
revoke all on function public.checkout(text,text,numeric,text,jsonb,numeric,numeric) from public, anon;
grant execute on function public.checkout(text,text,numeric,text,jsonb,numeric,numeric) to authenticated;
