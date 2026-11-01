-- Shop expenses (rent, electricity, salary, tea, transport...), shown on the dashboard.
-- Run once in the Supabase SQL editor of project "clothing-inventory".
create table if not exists public.expenses (
  id bigint generated always as identity primary key,
  spent_on date not null default current_date,
  category text not null check (length(trim(category)) > 0),
  amount numeric(10,2) not null check (amount > 0),
  pay_mode text not null default 'Cash' check (pay_mode in ('Cash','UPI','Bank')),
  note text,
  created_by uuid default auth.uid() references auth.users(id),
  created_by_email text default lower(coalesce(auth.jwt()->>'email','')),
  created_at timestamptz not null default now()
);
create index if not exists expenses_spent_on_idx on public.expenses(spent_on desc);
create index if not exists expenses_created_by_idx on public.expenses(created_by);

alter table public.expenses enable row level security;

-- Staff can see and add expenses; only owners can correct or delete them.
create policy expenses_select on public.expenses for select to authenticated
  using ((select public.is_staff()));
create policy expenses_insert on public.expenses for insert to authenticated
  with check ((select public.is_staff()));
create policy expenses_update on public.expenses for update to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));
create policy expenses_delete on public.expenses for delete to authenticated
  using ((select public.is_owner()));

-- Live updates across counters
alter publication supabase_realtime add table public.expenses;
