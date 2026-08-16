# NEELE SUPERMARKET — Setup

This is a two-file website — open either directly in a browser, or host both anywhere static (Netlify, Vercel, GitHub Pages, etc):

- **`index.html`** — the customer storefront (browse, cart, wishlist, checkout, My Orders, Track Order).
- **`admin.html`** — a completely separate admin dashboard at `/admin.html`. It is never linked from the storefront's main navigation and shares no UI or JS with `index.html`; a customer never sees admin controls. It has its own login screen (Supabase Auth).

It works out of the box in **demo mode** (products + cart + wishlist are stored in your browser's localStorage), so you can preview everything immediately. To make it fully live on **Supabase**:

## 1. Create a Supabase project
Go to [supabase.com](https://supabase.com) → New project.

## 2. Run the schema
Open **SQL Editor** in your Supabase dashboard, paste the entire contents of `schema.sql`, and run it. This creates:
- `products` — your catalog (pre-seeded with 16 demo items)
- `cart_items` — each visitor's basket (keyed by an anonymous device id stored in their browser)
- `likes` — each visitor's wishlist
- `orders` — every "Buy now" / checkout confirmation
- `order_status_history` — one row per status change, auto-populated by a trigger whenever an order is created or its status changes; powers the customer's tracking timeline

It's safe to re-run `schema.sql` on a project that already has the older version — it only adds the new columns/table/functions and normalises old `packed` statuses to `preparing`; it never drops your existing orders.

## 3. Connect the site
In your Supabase dashboard go to **Project Settings → API**, copy:
- **Project URL**
- **anon public key**

Open `index.html`, find this near the top of the `<script>` block, and paste your values in:

```js
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

Save and reload — the pill in the header will switch from **"Demo mode"** to **"Supabase live"**, and every add-to-cart, like, and order will now be written to your database in real time.

## 4. Create the product photo bucket (if the SQL step didn't create it)
`schema.sql` tries to create a public **`product-images`** storage bucket automatically. If your project blocks that from the SQL editor, create it by hand: **Storage → New bucket → name it `product-images` → toggle "Public bucket" on.** This is where the admin dashboard uploads photos to.

## Customer accounts
A **Sign in** button in the header opens a sign in / sign up modal backed by Supabase Auth (email + password). Signed-in shoppers get their name/email pre-filled at checkout. Auth is optional — anyone can still check out as a guest by filling in the delivery details form. In demo mode (no Supabase connected), the account button just lets you know accounts need Supabase.

## Admin dashboard (`admin.html`)
Admin access is a real Supabase Auth login — nothing is hard-coded into `admin.html`, and there's nothing to read out of the page source. To set up your one admin account:

1. In the Supabase dashboard, go to **Authentication → Users → Add user** and create the admin with an email + password.
2. Copy that user's **UID** from the users list.
3. In **SQL Editor**, run:
   ```sql
   insert into admins (user_id) values ('paste-the-uid-here');
   ```
4. Open `admin.html` directly (e.g. `yourdomain.com/admin.html`) and sign in with that email + password.

Only accounts listed in the `admins` table can add/edit/delete products, upload images, view orders, or change order status — this is enforced by Row Level Security in `schema.sql`, not just by the login screen, so it holds even if someone calls the Supabase API directly with the public anon key. To add a second admin later, repeat steps 1–3 with their account. To revoke access, delete their row from `admins`.

From the dashboard you can:
- **Overview tab** — total products, total orders, and counts of pending / confirmed / out-for-delivery / delivered orders, plus a feed of the latest orders.
- **Products tab** — add, edit, or delete products: name, category, unit, price, an optional **offer price** (shown as a strike-through deal on the storefront when it's lower than the price), stock, product code, description, and a photo upload (saved to the `product-images` bucket).
- **Orders tab** — see every order with the customer's name, contact number, delivery address, the product(s) and product code(s) ordered, total, and a status dropdown (Pending / Confirmed / Preparing / Out for Delivery / Delivered / Cancelled) you can update on the spot. Every change is written to `order_status_history` automatically by a database trigger, which is what powers the customer's tracking timeline.

**New-order notifications:** click **🔊 Enable Order Notifications** once (browsers block audio until a user gesture). After that, new orders play a short tone (synthesized in-browser, no audio file needed) and show a toast + an entry in the bell menu, in real time via Supabase Realtime with a 20-second polling fallback if Realtime isn't enabled on your project. Each order only ever triggers one notification per browser session — the last-seen order id is remembered in `localStorage`, so refreshing the page never replays old orders.

## Customer order history & tracking
Customers get a **My Orders** button in the header (device-scoped, same anonymous `device_id` used for cart/wishlist — no sign-in required) and a **Track Order** button on each order that opens a status timeline (Order Placed → Confirmed → Preparing → Out for Delivery → Delivered, or Cancelled). Status-change notifications (toast + sound + bell) appear automatically via a lightweight poll — see the security note below for why this is polling rather than Realtime on the customer side.

## Managing products
You can still add, edit, or remove rows in the `products` table directly from the Supabase Table Editor as before — the storefront re-fetches them on every page load. Fields:
- `icon` must match one of the built-in icon keys (`apple`, `banana`, `orange`, `grapes`, `carrot`, `broccoli`, `tomato`, `potato`, `milk`, `cheese`, `egg`, `bread`, `croissant`, `chips`, `cookie`, `juice`, or `leaf` as a generic fallback) — used only when a product has no `image_url`. Or add your own SVG to the `ICONS` object in `index.html`.
- `category` should be one of: `fruits`, `vegetables`, `dairy`, `bakery`, `snacks`, `beverages` (or add a new one to the `CATEGORIES` array in `index.html`).
- `offer_price`, `image_url`, and `product_code` are all optional.

## Notes
- Shoppers aren't required to log in to shop — each browser gets a random anonymous `device_id` (stored in localStorage) that scopes their cart, wishlist, and now their order history too. Every checkout collects delivery details directly. Signing in (Supabase Auth) just pre-fills those details.
- Row Level Security is enabled on every table. Products can be **read** by anyone (browsing) and orders can be **inserted** by anyone (checkout), but direct SELECT/UPDATE on `orders`, writes to `products`, and uploads to the `product-images` bucket all require a Supabase Auth session listed in the `admins` table — checked server-side by Postgres, not by the browser. `cart_items` and `likes` stay open per-device since they're anonymous, non-sensitive scratch data.

### Customer order security — what changed and its limits
Orders contain names, phone numbers and addresses, so unlike cart/likes they're **not** given an open per-device RLS policy. Instead, two Postgres functions (`get_my_orders`, `get_order_tracking` in `schema.sql`) filter to the caller's `device_id` *inside* the function before returning anything — a shopper can only ever get back rows that already match the id stored in their own browser, and can never list or browse every order.

This is stronger than a fully-open policy, but it is still **not real account security**: `device_id` is a random client-generated token, never authenticated by Supabase Auth, so possessing that exact id is what grants access — the same trust model the original project already used for `cart_items`/`likes`, just applied more carefully here because orders are more sensitive. In practice the id isn't guessable (long random string), but if it ever leaked from that one browser's storage, whoever has it could call these functions with it.

If you need real per-customer security — so a customer's orders can never be shown to anyone else even from a leaked id — switch customer order access to Supabase Auth: add a `user_id uuid references auth.users` column to `orders`, require sign-in at checkout, and change `get_my_orders`/`get_order_tracking` (and a new RLS policy on `orders`) to check `auth.uid()` instead of a client-supplied `device_id`. That would also let you enable Supabase Realtime directly on the `orders` table for customers (right now Realtime for order updates is only wired up on the *admin* side, where a real authenticated session satisfies the RLS policy — the customer side uses a 25-second poll instead, which avoids ever opening the table to anonymous SELECT).
