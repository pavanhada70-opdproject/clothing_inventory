# Clothing Inventory (Garment POS online)

Online version of the store's offline Garment POS. A single page (`public/index.html`) that talks directly to its own Supabase project. It is kept separate from the OPD and MedStock projects: own repo, own database, own subdomain.

## Features

- **POS billing** with barcode scan, flat discount, Cash / UPI / Udhaar or a split of all three on one bill (the unpaid part goes to the customer's udhaar), change to return, thermal slip printing and WhatsApp bills
- **Stock** list with inline price, category and reorder-level edits, and flags for rows that need a check
- **Supplier purchase bills**: enter lines (or a size set like M, L, XL), attach a bill photo, then "Add to stock". Matching items get stock added; new ones are created
- **Customers & udhaar**: customers are saved from the mobile number at billing; see bills, receive udhaar payments, send WhatsApp reminders
- **Stock log**: append-only record of every sale, purchase and manual change, with who made it
- **Dashboard**: today / 30-day sales, stock value, udhaar outstanding, low stock (at or below reorder level), slow-moving stock (no sale in 90 days), pieces by type
- **Staff & roles**: only emails on the staff list can see data; owners can delete and manage staff
- **Backup**: inventory and sales CSV, full JSON backup, CSV import
- Live sync between open counters, phone layout with bottom tabs

## Setup

1. Create a Supabase project and run the files in `supabase/migrations/` in order in the SQL editor. Change the owner email in `0002_medstock_features.sql` first if needed.
2. Put the project URL and publishable key at the top of the `<script>` in `public/index.html` (`SUPABASE_URL`, `SUPABASE_KEY`). The publishable key is meant to be public; access is enforced by Row Level Security.
3. In Supabase → Authentication → URL Configuration, set the Site URL to where the page is hosted.
4. Host the `public/` folder on any static host (it has no build step). On Railway, `Staticfile` tells Railpack to serve only `public/`, so the SQL and tools are never published. Open it, create an account with the owner email, confirm it, and sign in.

## Security

- Row Level Security on every table. `is_staff()` / `is_owner()` check the signed-in email against `public.staff`; restrictive policies make every table staff-only and item deletes owner-only.
- Stock changes from sales and purchases go through `checkout()` and `commit_purchase()`, which lock rows and run as the caller, so RLS still applies.
- Bill photos are in a private `bills` bucket, viewed through 5-minute signed URLs.
- Never put the service-role key or database password in this repo.

## Tools

`tools/clean_stock.py` is the one-off script that cleaned the original offline stock export (brand spellings, combined size cells, Kids/Men waist sizes) before the first load.
