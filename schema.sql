-- =========================================================
-- NEELE SUPERMARKET — Supabase schema
-- Run this whole file in your Supabase project's SQL editor
-- (Dashboard → SQL Editor → New query → Run). It's safe to
-- run more than once — existing tables/columns/policies are
-- left alone or replaced instead of erroring out.
-- Then copy your Project URL and anon public key into
-- SUPABASE_URL / SUPABASE_ANON_KEY at the top of index.html.
-- =========================================================

-- ---------- PRODUCTS ----------
create table if not exists products (
  id            bigint primary key,
  name          text not null,
  category      text not null,
  price         numeric not null,
  unit          text not null default '1 pc',
  stock         int not null default 0,
  icon          text not null default 'leaf',
  "desc"        text default ''     -- quoted: "desc" is a reserved SQL keyword
);

-- Adds the new columns if this table already existed from an earlier version of this file.
alter table products add column if not exists offer_price  numeric;   -- optional discounted price; shown as a strike-through deal when set and lower than price
alter table products add column if not exists image_url    text;      -- uploaded product photo (from the "product-images" storage bucket)
alter table products add column if not exists product_code text;      -- shown to the admin / on orders; falls back to "NS-<id>" if left blank

-- ---------- CART ITEMS (per anonymous device) ----------
create table if not exists cart_items (
  device_id   text not null,
  product_id  bigint not null references products(id) on delete cascade,
  qty         int not null default 1,
  updated_at  timestamptz not null default now(),
  primary key (device_id, product_id)
);

-- ---------- LIKES / WISHLIST (per anonymous device) ----------
create table if not exists likes (
  device_id   text not null,
  product_id  bigint not null references products(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (device_id, product_id)
);

-- ---------- ADMINS ----------
-- One row per Supabase Auth user allowed to manage products/orders.
-- Create the admin's login under Authentication -> Users (email + password),
-- then insert their auth.users id here — e.g.:
--   insert into admins (user_id) values ('paste-the-user-uuid-here');
create table if not exists admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

-- ---------- ORDERS ----------
create table if not exists orders (
  id          bigint generated always as identity primary key,
  device_id   text not null,
  items       jsonb not null,        -- [{product_id, product_code, name, qty, price}, ...]
  total       numeric not null,
  status      text not null default 'confirmed',
  created_at  timestamptz not null default now()
);

-- Adds the new columns if this table already existed from an earlier version of this file.
alter table orders add column if not exists customer_name text;
alter table orders add column if not exists phone         text;
alter table orders add column if not exists address       text;
alter table orders add column if not exists email         text;
alter table orders add column if not exists updated_at    timestamptz not null default now();

-- Normalises the old two-stage status vocabulary ("confirmed"/"packed"/"delivered"/"cancelled")
-- onto the new five-stage tracking flow. Existing orders are kept, only the label changes.
update orders set status = 'preparing' where status = 'packed';
update orders set status = 'confirmed' where status is null or status = '';

-- ---------- ORDER STATUS HISTORY ----------
-- One row per status change (plus the initial "pending" row on insert). Powers the
-- customer-facing tracking timeline. Never written to directly from the client —
-- only by the trigger below — so it can't be forged.
create table if not exists order_status_history (
  id          bigint generated always as identity primary key,
  order_id    bigint not null references orders(id) on delete cascade,
  status      text not null,
  created_at  timestamptz not null default now()
);
create index if not exists order_status_history_order_id_idx on order_status_history(order_id);

-- Backfill a history row for any pre-existing order that doesn't have one yet,
-- so the tracking timeline has at least one entry for old orders.
insert into order_status_history (order_id, status, created_at)
select o.id, o.status, o.created_at
from orders o
where not exists (select 1 from order_status_history h where h.order_id = o.id);

-- Keeps updated_at current and appends a history row whenever the status actually changes
-- (also fires once on insert so every order starts with a history entry).
create or replace function handle_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    insert into order_status_history (order_id, status) values (new.id, new.status);
    return new;
  end if;
  if TG_OP = 'UPDATE' then
    new.updated_at := now();
    if new.status is distinct from old.status then
      insert into order_status_history (order_id, status) values (new.id, new.status);
    end if;
    return new;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_status_insert on orders;
create trigger orders_status_insert
  after insert on orders
  for each row execute function handle_order_status_change();

drop trigger if exists orders_status_update on orders;
create trigger orders_status_update
  before update on orders
  for each row execute function handle_order_status_change();

-- New orders now start life as "pending" ("Order Placed"), matching the tracking timeline.
alter table orders alter column status set default 'pending';

-- =========================================================
-- ROW LEVEL SECURITY
-- Admin-only actions (product writes, image uploads, viewing
-- orders, updating order status) are gated on a real Supabase
-- Auth session that is also listed in the "admins" table below
-- — not on a client-side password check. Shoppers keep working
-- anonymously via device_id for cart/likes/checkout.
-- =========================================================

alter table products enable row level security;
alter table cart_items enable row level security;
alter table likes enable row level security;
alter table orders enable row level security;
alter table admins enable row level security;
alter table order_status_history enable row level security;

-- is_admin(): true only for a logged-in Supabase Auth user whose id
-- appears in the admins table. security definer so it can read the
-- admins table even from policies on other tables.
create or replace function is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from admins where user_id = auth.uid()
  );
$$;

-- admins: each admin can see their own row; nobody can write to it
-- from the client (add admins via the SQL editor / dashboard only).
drop policy if exists "Admins can read own row" on admins;
create policy "Admins can read own row" on admins
  for select using (auth.uid() = user_id);

-- products: everyone can browse; only an admin can write.
drop policy if exists "Public can read products" on products;
create policy "Public can read products" on products
  for select using (true);

drop policy if exists "Anyone can add, edit or remove products" on products;
drop policy if exists "Admins can insert products" on products;
create policy "Admins can insert products" on products
  for insert with check (is_admin());

drop policy if exists "Anyone can update products" on products;
drop policy if exists "Admins can update products" on products;
create policy "Admins can update products" on products
  for update using (is_admin()) with check (is_admin());

drop policy if exists "Anyone can delete products" on products;
drop policy if exists "Admins can delete products" on products;
create policy "Admins can delete products" on products
  for delete using (is_admin());

-- cart_items / likes: still open per-device (anonymous shopping,
-- scoped by a random device_id, not sensitive data).
drop policy if exists "Anyone can manage their own cart" on cart_items;
create policy "Anyone can manage their own cart" on cart_items
  for all using (true) with check (true);

drop policy if exists "Anyone can manage their own likes" on likes;
create policy "Anyone can manage their own likes" on likes
  for all using (true) with check (true);

-- orders: any shopper (incl. anonymous) can place an order, but only
-- an admin can list existing orders or change their status.
drop policy if exists "Anyone can insert and read orders" on orders;

drop policy if exists "Anyone can place an order" on orders;
create policy "Anyone can place an order" on orders
  for insert with check (true);

drop policy if exists "Admins can view orders" on orders;
create policy "Admins can view orders" on orders
  for select using (is_admin());

drop policy if exists "Admins can update order status" on orders;
create policy "Admins can update order status" on orders
  for update using (is_admin()) with check (is_admin());

drop policy if exists "Admins can delete orders" on orders;
create policy "Admins can delete orders" on orders
  for delete using (is_admin());

-- order_status_history: only admins can read it directly. Customers reach their
-- own order's history exclusively through get_order_tracking() below.
drop policy if exists "Admins can view order status history" on order_status_history;
create policy "Admins can view order status history" on order_status_history
  for select using (is_admin());

-- =========================================================
-- CUSTOMER ORDER ACCESS (device_id, no Supabase Auth required)
-- ---------------------------------------------------------
-- Direct SELECT on "orders" stays admin-only (policy above) so a client can
-- never list every order. Customers instead call these two functions with
-- their own device_id; each one filters to that device_id *inside* the
-- function before returning anything, so a shopper can only ever see rows
-- that already match the id stored in their own browser.
--
-- SECURITY NOTE (see README "Customer accounts" section for the long
-- version): device_id is a random token generated client-side and never
-- authenticated — exactly like the existing cart_items/likes design. That
-- makes this "possession of the id" security, not real account security:
-- anyone who obtains a specific device_id (e.g. it leaks from that user's
-- own browser storage) could call these functions with it. It is NOT
-- guessable in practice (a long random string) and, unlike the previous
-- fully-open policy, a visitor can no longer list *all* orders or browse
-- other customers' data without already having their id. If you need
-- real per-customer security (e.g. so a customer can never be shown
-- another customer's order even with a leaked id), switch customers to
-- Supabase Auth and add a "user_id uuid references auth.users" column to
-- orders, then change these functions (and the RLS policy on orders) to
-- check auth.uid() instead of a client-supplied device_id.
-- =========================================================

create or replace function get_my_orders(p_device_id text)
returns setof orders
language sql
security definer
set search_path = public
stable
as $$
  select * from orders
  where device_id = p_device_id
  order by created_at desc;
$$;

create or replace function get_order_tracking(p_order_id bigint, p_device_id text)
returns table (
  order_id      bigint,
  status        text,
  created_at    timestamptz,
  updated_at    timestamptz,
  total         numeric,
  items         jsonb,
  customer_name text,
  phone         text,
  address       text,
  history       jsonb
)
language sql
security definer
set search_path = public
stable
as $$
  select
    o.id, o.status, o.created_at, o.updated_at, o.total, o.items,
    o.customer_name, o.phone, o.address,
    coalesce(
      (select jsonb_agg(jsonb_build_object('status', h.status, 'created_at', h.created_at) order by h.created_at)
       from order_status_history h where h.order_id = o.id),
      '[]'::jsonb
    ) as history
  from orders o
  where o.id = p_order_id and o.device_id = p_device_id;
$$;

grant execute on function get_my_orders(text) to anon, authenticated;
grant execute on function get_order_tracking(bigint, text) to anon, authenticated;

-- =========================================================
-- STORAGE — product photos
-- Creates a public bucket the admin dashboard uploads into.
-- Wrapped in DO blocks so this section never aborts the rest
-- of the script — some Supabase projects restrict SQL-editor
-- access to the storage schema. If it's skipped, just create
-- the bucket by hand instead:
-- Dashboard → Storage → New bucket → name it "product-images" → Public bucket ON.
-- =========================================================

do $$
begin
  insert into storage.buckets (id, name, public)
  values ('product-images', 'product-images', true)
  on conflict (id) do nothing;
exception when others then
  raise notice 'Could not create the "product-images" bucket automatically (%). Create it by hand in Storage instead.', sqlerrm;
end $$;

do $$
begin
  drop policy if exists "Public can view product images" on storage.objects;
  create policy "Public can view product images" on storage.objects
    for select using (bucket_id = 'product-images');

  drop policy if exists "Anyone can upload product images" on storage.objects;
  drop policy if exists "Admins can upload product images" on storage.objects;
  create policy "Admins can upload product images" on storage.objects
    for insert with check (bucket_id = 'product-images' and is_admin());

  drop policy if exists "Anyone can replace product images" on storage.objects;
  drop policy if exists "Admins can replace product images" on storage.objects;
  create policy "Admins can replace product images" on storage.objects
    for update using (bucket_id = 'product-images' and is_admin()) with check (bucket_id = 'product-images' and is_admin());

  drop policy if exists "Anyone can delete product images" on storage.objects;
  drop policy if exists "Admins can delete product images" on storage.objects;
  create policy "Admins can delete product images" on storage.objects
    for delete using (bucket_id = 'product-images' and is_admin());
exception when others then
  raise notice 'Could not create storage policies automatically (%). Set them up from Storage → product-images → Policies instead.', sqlerrm;
end $$;

-- =========================================================
-- SEED PRODUCTS
-- (matches the demo data baked into index.html, so the
-- storefront looks identical once Supabase is connected)
-- =========================================================

insert into products (id, name, category, price, unit, stock, icon, product_code, "desc") values
  (1,  'Royal Gala Apples',        'fruits',     129, '1 kg',   24, 'apple',     'NS-001', 'Crisp, sweet and hand-picked daily.'),
  (2,  'Cavendish Bananas',        'fruits',     59,  '1 dozen',40, 'banana',    'NS-002', 'Naturally ripened, no gas treatment.'),
  (3,  'Juicy Oranges',            'fruits',     89,  '1 kg',   18, 'orange',    'NS-003', 'Tangy-sweet, packed with vitamin C.'),
  (4,  'Black Grapes',             'fruits',     149, '500 g',  9,  'grapes',    'NS-004', 'Seedless and bursting with juice.'),
  (5,  'Fresh Carrots',            'vegetables', 39,  '500 g',  30, 'carrot',    'NS-005', 'Crunchy, sweet, straight from the farm.'),
  (6,  'Organic Broccoli',         'vegetables', 79,  '1 pc',   14, 'broccoli',  'NS-006', 'Locally grown, pesticide-free.'),
  (7,  'Vine Tomatoes',            'vegetables', 49,  '500 g',  26, 'tomato',    'NS-007', 'Ripened on the vine for full flavour.'),
  (8,  'Baby Potatoes',            'vegetables', 35,  '1 kg',   5,  'potato',    'NS-008', 'Perfect for roasting or curries.'),
  (9,  'Farm Fresh Milk',          'dairy',      56,  '1 L',    22, 'milk',      'NS-009', 'Pasteurised, delivered chilled.'),
  (10, 'Aged Cheddar Cheese',      'dairy',      189, '200 g',  11, 'cheese',    'NS-010', 'Sharp, creamy and full-bodied.'),
  (11, 'Free-range Eggs',          'dairy',      92,  '12 pc',  17, 'egg',       'NS-011', 'From happy, pasture-raised hens.'),
  (12, 'Multigrain Bread',         'bakery',     48,  '400 g',  20, 'bread',     'NS-012', 'Baked fresh every morning.'),
  (13, 'Butter Croissants',        'bakery',     39,  '2 pc',   8,  'croissant', 'NS-013', 'Flaky, buttery, straight from the oven.'),
  (14, 'Sea Salt Chips',           'snacks',     30,  '90 g',   35, 'chips',     'NS-014', 'Crispy potato chips, lightly salted.'),
  (15, 'Choco Chip Cookies',       'snacks',     65,  '200 g',  19, 'cookie',    'NS-015', 'Loaded with real chocolate chunks.'),
  (16, 'Cold-pressed Orange Juice','beverages',  115, '1 L',    13, 'juice',     'NS-016', 'No added sugar, 100% fruit.')
on conflict (id) do nothing;