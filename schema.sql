-- ============================================================
-- Workline — Supabase schema
-- Run once: Supabase Dashboard → SQL Editor → New query → paste → Run
-- ============================================================

create table people (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  phone text unique,
  color text not null,
  is_admin boolean not null default false,
  -- Can create jobs (process, fields, setup) and edit a job's own process,
  -- but not manage the team, alerts, standard process templates, or
  -- update other people's tasks. Irrelevant if is_admin is already true.
  is_co_admin boolean not null default false,
  tutorial_seen boolean not null default false,
  auth_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table process_chains (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  blurb text default '',
  created_at timestamptz not null default now()
);

create table chain_tasks (
  id uuid primary key default gen_random_uuid(),
  chain_id uuid not null references process_chains(id) on delete cascade,
  name text not null,
  owner_name text,
  days integer not null default 1,
  pos_x real, pos_y real,
  sort_order integer not null default 0
);

create table chain_edges (
  id uuid primary key default gen_random_uuid(),
  chain_id uuid not null references process_chains(id) on delete cascade,
  from_task uuid not null references chain_tasks(id) on delete cascade,
  to_task uuid not null references chain_tasks(id) on delete cascade,
  edge_type text not null default 'FS' check (edge_type in ('FS','SS'))
);

-- Custom fields: replaces Amber's hardcoded marca/width/selvedge/etc. Every
-- field a business wants to track on a job — text, number, date, or a
-- managed dropdown — is defined here by the admin, not hardcoded in code.
create table job_field_defs (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  field_key text not null unique check (field_key ~ '^[a-z][a-z0-9_]*$'),
  type text not null check (type in ('text','number','date','select')),
  sort_order integer not null default 0,
  required boolean not null default false,
  created_at timestamptz not null default now()
);

-- Reusable dropdown values for any 'select'-type field def (generalizes
-- Amber's single-purpose "Qualities" list to work for any field).
create table field_options (
  id uuid primary key default gen_random_uuid(),
  field_key text not null references job_field_defs(field_key) on delete cascade,
  value text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- A job's own custom field values live in one jsonb blob, keyed by
-- field_key, always stored as strings (the field_def's `type` only
-- controls which input widget renders and how exports coerce the value —
-- it is never used to decide the on-disk JSON type, so sorting/equality
-- checks in the client stay consistent regardless of a field's type).
-- `client` and `chain_id` stay as real columns, not custom fields: client
-- feeds job-code generation and chain_id drives which process template's
-- tasks get instantiated — both are structural, not descriptive data.
create table jobs (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  client text not null,
  chain_id uuid references process_chains(id) on delete set null,
  chain_label_snapshot text,
  start_date date not null,
  ship_date date,
  custom_fields jsonb not null default '{}'::jsonb,
  on_hold boolean not null default false,
  -- Cumulative days the job's future schedule has shifted by, across every
  -- pause/resume cycle — added to start_date when recomputing planned
  -- dates for tasks that haven't happened yet. Completed/in-progress
  -- tasks' own history is never rewritten.
  hold_days integer not null default 0,
  created_at timestamptz not null default now()
);

create table job_links (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  url text not null,
  label text default '',
  added_by text,
  created_at timestamptz not null default now()
);

create table job_comments (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  text text not null,
  author text not null,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  acked boolean not null default false
);

create table tasks (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  name text not null,
  owner_name text,
  days integer not null default 1,
  status text not null default 'pending' check (status in ('pending','in_progress','completed')),
  actual_start date,
  actual_end date,
  planned_start date,
  pos_x real, pos_y real,
  created_at timestamptz not null default now()
);

create table task_edges (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  from_task uuid not null references tasks(id) on delete cascade,
  to_task uuid not null references tasks(id) on delete cascade,
  edge_type text not null default 'FS' check (edge_type in ('FS','SS'))
);

-- One row per pause/resume cycle, so a long-running job's timeline is
-- never a mystery — "paused here, resumed there, chosen mode X" stays on
-- the record even after the job finishes.
create table job_holds (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  task_id uuid references tasks(id) on delete set null,
  task_name_snapshot text,
  paused_at date not null,
  paused_by text,
  resumed_at date,
  resumed_by text,
  resume_mode text check (resume_mode in ('resume','restart')),
  created_at timestamptz not null default now()
);

create table task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references tasks(id) on delete cascade,
  text text not null,
  author text not null,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  acked boolean not null default false
);

create table task_reminders (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references tasks(id) on delete cascade,
  text text not null,
  due_date date,
  created_by text,
  created_at timestamptz not null default now(),
  status text not null default 'open' check (status in ('open','resolved')),
  resolved_at timestamptz,
  resolved_by text,
  resolved_via text,
  reply_comment_id uuid references task_comments(id) on delete set null
);

create table push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references people(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);

create table notification_log (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references people(id) on delete cascade,
  item_type text not null,
  item_id uuid not null,
  sent_at timestamptz not null default now()
);

-- Single settings row: notification cadence + this instance's branding.
-- logo_light/logo_dark are base64 data URIs (client-side canvas-resized
-- before upload, capped ~512x512) rather than Supabase Storage — keeps
-- self-hosting to "run this file," no storage bucket to configure.
create table app_settings (
  id boolean primary key default true check (id),
  wa_threshold integer not null default 5,
  notify_days integer[] not null default '{1,2,3,4,5}', -- 0=Sun..6=Sat
  company_name text not null default 'Workline',
  logo_light text,
  logo_dark text,
  primary_color text not null default '#1E4B7A'
);
insert into app_settings (id) values (true);

-- ============================================================
-- Row Level Security. Every table requires a signed-in user and nothing
-- more granular than that — any authenticated team member can read/write
-- any row in any table (including other people's comments/reminders).
-- That's an intentional simplicity trade-off for a small trusted team,
-- not an oversight — see the README's security note before self-hosting
-- this for a team you don't fully trust with each other's data.
-- ============================================================
alter table people enable row level security;
alter table process_chains enable row level security;
alter table chain_tasks enable row level security;
alter table chain_edges enable row level security;
alter table job_field_defs enable row level security;
alter table field_options enable row level security;
alter table jobs enable row level security;
alter table job_links enable row level security;
alter table job_comments enable row level security;
alter table job_holds enable row level security;
alter table tasks enable row level security;
alter table task_edges enable row level security;
alter table task_comments enable row level security;
alter table task_reminders enable row level security;
alter table push_subscriptions enable row level security;
alter table notification_log enable row level security;
alter table app_settings enable row level security;

create policy "signed-in users only" on people for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on process_chains for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on chain_tasks for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on chain_edges for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on job_field_defs for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on field_options for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on jobs for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on job_links for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on job_comments for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on job_holds for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on tasks for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on task_edges for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on task_comments for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on task_reminders for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on push_subscriptions for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on notification_log for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "signed-in users only" on app_settings for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- ============================================================
-- First-run bootstrap: creates the first admin account when the team is
-- genuinely empty (a brand-new instance, or every person was deleted).
-- A security-definer function rather than an RLS hole on `people` — it
-- runs with elevated privilege internally, checks the team is empty
-- inside the same transaction (atomic, no race window), and grants
-- nothing broader to anonymous visitors than "call this one function."
-- The client calls it via sb.rpc('bootstrap_first_admin', {...}) instead
-- of a normal insert, only when the login screen finds zero people.
-- ============================================================
create or replace function bootstrap_first_admin(p_name text, p_color text)
returns people
language plpgsql
security definer
set search_path = public
as $$
declare
  new_row people;
begin
  if (select count(*) from people) > 0 then
    raise exception 'Team already has members — use the normal add-person flow.';
  end if;
  insert into people (name, is_admin, color, tutorial_seen)
  values (p_name, true, p_color, false)
  returning * into new_row;
  return new_row;
end;
$$;

grant execute on function bootstrap_first_admin(text, text) to anon;
