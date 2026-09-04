# Workline

A self-hosted process tracker for businesses that run the **same handful of
workflows across many repeating jobs** — manufacturers, exporters,
wholesalers, garment/textile/food production, print shops. It's a poor fit
for project-based or bespoke work (agencies, software, construction) where
every engagement has a different structure.

Admins define:
- **Process templates** — a chain of tasks with dependencies (some start
  after the previous one finishes, some once it merely starts), each with
  an owner and a days-allowed budget. Every new job is instantiated from
  one of these.
- **Job fields** — whatever your business actually tracks per job (a batch
  number, a grade, a width, anything) as text, number, date, or a managed
  dropdown. Nothing is hardcoded — add, remove, and reorder fields from
  the Admin screen at any time.
- **Branding** — company name, brand color, and logo, uploaded right from
  the Admin screen. Updates the login screen, header, favicon, and PWA
  home-screen icon everywhere, for everyone.

Everyone else sees their tasks, comments on any job or task, leaves dated
reminders for whoever holds a task, and gets a push-notification digest on
whichever days of the week the admin schedules.

It's a single static HTML file plus a small Supabase backend — no server to
run, no build step. **No app store either** — installed via "Add to Home
Screen" (a real PWA: its own icon, full-screen, push notifications), which
costs nothing and doesn't require a store review.

## Setup

You'll need a free [Supabase](https://supabase.com) project and a free
[Netlify](https://netlify.com) site. Ten-ish minutes, no credit card.

### 1. Database

Supabase Dashboard → your project → **SQL Editor** → New query → paste the
entire contents of [`schema.sql`](schema.sql) → **Run**.

### 2. Push notifications

1. Generate a VAPID keypair — easiest via `npx web-push generate-vapid-keys`
   (needs Node; no install required with `npx`), or any VAPID key generator.
2. Supabase Dashboard → **Edge Functions** → create a function named
   `send-reminders` → paste in [`send-reminders.ts`](send-reminders.ts) →
   Deploy.
3. That function needs four secrets (Edge Functions → `send-reminders` →
   Settings, or `supabase secrets set` via CLI):
   - `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` — from step 1
   - `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` — Project Settings → API
     (the **service role** key, not the anon key — this function needs to
     read/write across every person's data, which the anon key's RLS
     policies deliberately don't allow)
4. Edit the `mailto:admin@example.com` line near the top of
   `send-reminders.ts` to a real contact address for this deployment
   before deploying — required by the Web Push spec.
5. Schedule it to run at least daily: Supabase Dashboard → **Database** →
   **Cron Jobs** → new job, e.g. `0 6 * * *` (06:00 UTC, every day),
   command `select net.http_post(url:='<your function URL>');`. The
   function itself decides whether today is actually one of the days the
   admin picked in-app — it's safe to invoke daily regardless of how often
   you actually want notifications sent.

### 3. The app itself

Open [`index.html`](index.html) and fill in, near the top of the `<script>`
block:
- `SUPABASE_URL`, `SUPABASE_ANON_KEY` — Project Settings → API (the
  **anon/publishable** key here, never the service role key)
- `PUBLIC_VAPID_KEY` — the public key from step 2.1

### 4. Deploy

Drag a folder containing **both** `index.html` and `sw.js` into Netlify's
Deploys tab (or connect a git repo — either works). `sw.js` must be
deployed alongside `index.html` at the site root, or push notifications
silently stop working — easy to miss since everything else keeps working
fine without it.

### 5. First run

Open the deployed site. With no one set up yet, it'll prompt to create the
first admin account. From there: Admin → set your company name, brand
color, and logo; add your team; build your first process template; define
whatever job fields your business actually needs.

### 6. Install as an app

Open the site on a phone, then "Add to Home Screen" (Safari on iOS,
Chrome's install prompt on Android). That's the step that also enables
push notifications on iOS — they don't work in a plain browser tab there.

## A note on data access

Every table uses one blanket policy: any signed-in team member can
read and write any row, including other people's comments, reminders, and
push subscriptions. There's no per-row ownership check. That's a deliberate
simplicity trade-off for a small trusted team, not an oversight — but know
it before self-hosting this for a team you don't fully trust with each
other's data.

## Wanting a real app-store listing?

Not something this project does centrally — see the main note above on
why a per-deployment app doesn't map cleanly onto one store listing. If a
specific deployment wants one anyway, wrapping a PWA for the Play Store
costs a one-time $25 Google Play developer fee (paid by whoever wants the
listing, not baked into this project) — [PWABuilder](https://pwabuilder.com)
can generate the wrapper from your deployed URL. Apple's App Store is
$99/year recurring and reviews thin PWA-wrapper apps more strictly, so it's
not recommended for a templated app like this.

## License

MIT — see [`LICENSE`](LICENSE).
