# NEELE SUPERMARKET — Setup

This is a single-file website (`index.html`) — open it directly in a browser, or host it anywhere static (Netlify, Vercel, GitHub Pages, etc).

It works out of the box in **demo mode** (products + cart + wishlist are stored in your browser's localStorage), so you can preview everything immediately. To make it fully live on **Supabase**:

## 1. Create a Supabase project
Go to [supabase.com](https://supabase.com) → New project.

## 2. Run the schema
Open **SQL Editor** in your Supabase dashboard, paste the entire contents of `schema.sql`, and run it. This creates:
- `products` — your catalog (pre-seeded with 16 demo items)
- `cart_items` — each visitor's basket (keyed by an anonymous device id stored in their browser)
- `likes` — each visitor's wishlist
- `orders` — every "Buy now" / checkout confirmation

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

## Admin dashboard
Admin access is a real Supabase Auth login now — nothing is hard-coded into `index.html`, and there's nothing to read out of the page source. To set up your one admin account:

1. In the Supabase dashboard, go to **Authentication → Users → Add user** and create the admin with an email + password.
2. Copy that user's **UID** from the users list.
3. In **SQL Editor**, run:
   ```sql
   insert into admins (user_id) values ('paste-the-uid-here');
   ```
4. On the site, click **Admin** in the header and sign in with that email + password.

Only accounts listed in the `admins` table can add/edit/delete products, upload images, view orders, or change order status — this is enforced by Row Level Security in `schema.sql`, not just by the login screen, so it holds even if someone calls the Supabase API directly with the public anon key. To add a second admin later, repeat steps 1–3 with their account. To revoke access, delete their row from `admins`.

From the dashboard you can:
- **Products tab** — add, edit, or delete products: name, category, unit, price, an optional **offer price** (shown as a strike-through deal on the storefront when it's lower than the price), stock, product code, description, and a photo upload (saved to the `product-images` bucket).
- **Orders tab** — see every order with the customer's name, contact number, delivery address, the product(s) and product code(s) ordered, total, and a status dropdown (confirmed / packed / delivered / cancelled) you can update on the spot.

## Managing products
You can still add, edit, or remove rows in the `products` table directly from the Supabase Table Editor as before — the storefront re-fetches them on every page load. Fields:
- `icon` must match one of the built-in icon keys (`apple`, `banana`, `orange`, `grapes`, `carrot`, `broccoli`, `tomato`, `potato`, `milk`, `cheese`, `egg`, `bread`, `croissant`, `chips`, `cookie`, `juice`, or `leaf` as a generic fallback) — used only when a product has no `image_url`. Or add your own SVG to the `ICONS` object in `index.html`.
- `category` should be one of: `fruits`, `vegetables`, `dairy`, `bakery`, `snacks`, `beverages` (or add a new one to the `CATEGORIES` array in `index.html`).
- `offer_price`, `image_url`, and `product_code` are all optional.

## Notes
- Shoppers aren't required to log in to shop — each browser gets a random anonymous `device_id` (stored in localStorage) that scopes their cart and wishlist, and every checkout collects delivery details directly. Signing in (Supabase Auth) just pre-fills those details and is the seed for real per-account order history later.
- Row Level Security is enabled on every table. Products and orders can be **read** by anyone (browsing) and orders can be **inserted** by anyone (checkout), but writing to `products`, viewing or updating `orders`, and uploading to the `product-images` bucket all require a Supabase Auth session that's listed in the `admins` table — checked server-side by Postgres, not by the browser. `cart_items` and `likes` stay open per-device since they're anonymous, non-sensitive scratch data.
