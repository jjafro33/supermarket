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

-- =========================================================
-- ROW LEVEL SECURITY
-- This demo uses an anonymous per-browser device_id (stored
-- in localStorage) instead of Supabase Auth, so policies are
-- kept open for the anon key. For production, swap in
-- Supabase Auth + auth.uid()-scoped policies instead.
-- =========================================================

alter table products enable row level security;
alter table cart_items enable row level security;
alter table likes enable row level security;
alter table orders enable row level security;

drop policy if exists "Public can read products" on products;
create policy "Public can read products" on products
  for select using (true);

-- The admin dashboard (username/password login built into index.html) writes
-- products using the same public anon key as the storefront, since there's no
-- Supabase Auth layer yet. Keep this open for now; tighten it (e.g. require
-- auth.role() = 'authenticated' or a service-role edge function) before you
-- hand real product management over to more than one trusted person.
drop policy if exists "Anyone can add, edit or remove products" on products;
create policy "Anyone can add, edit or remove products" on products
  for insert with check (true);

drop policy if exists "Anyone can update products" on products;
create policy "Anyone can update products" on products
  for update using (true) with check (true);

drop policy if exists "Anyone can delete products" on products;
create policy "Anyone can delete products" on products
  for delete using (true);

drop policy if exists "Anyone can manage their own cart" on cart_items;
create policy "Anyone can manage their own cart" on cart_items
  for all using (true) with check (true);

drop policy if exists "Anyone can manage their own likes" on likes;
create policy "Anyone can manage their own likes" on likes
  for all using (true) with check (true);

drop policy if exists "Anyone can insert and read orders" on orders;
create policy "Anyone can insert and read orders" on orders
  for all using (true) with check (true);

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
  create policy "Anyone can upload product images" on storage.objects
    for insert with check (bucket_id = 'product-images');

  drop policy if exists "Anyone can replace product images" on storage.objects;
  create policy "Anyone can replace product images" on storage.objects
    for update using (bucket_id = 'product-images') with check (bucket_id = 'product-images');

  drop policy if exists "Anyone can delete product images" on storage.objects;
  create policy "Anyone can delete product images" on storage.objects
    for delete using (bucket_id = 'product-images');
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