-- Paste this into your Supabase project's SQL editor and run.
--
-- After running this, add `sozoread://login-callback` to the allowed
-- redirect URLs in Supabase Dashboard -> Authentication -> URL Configuration
-- (both "Site URL" and the "Redirect URLs" allowlist). The magic-link emails
-- won't work otherwise.

-- ---------------------------------------------------------------------------
-- library_entries: one row per (user, source, book) the user has saved.
-- The full BookItem JSON is stashed so the app can re-render covers and
-- titles without a fresh network fetch.
-- ---------------------------------------------------------------------------
create table if not exists public.library_entries (
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text not null,
  book_id text not null,
  book_json jsonb not null,
  status text not null default 'reading',
  added_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_chapter_index int not null default 0,
  last_chapter_progress real,
  primary key (user_id, source_id, book_id)
);

create index if not exists library_entries_updated_at_idx
  on public.library_entries (updated_at desc);

-- ---------------------------------------------------------------------------
-- read_chapters: one row per chapter the user has finished reading.
-- ---------------------------------------------------------------------------
create table if not exists public.read_chapters (
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id text not null,
  book_id text not null,
  chapter_id text not null,
  read_at timestamptz not null default now(),
  primary key (user_id, source_id, book_id, chapter_id)
);

create index if not exists read_chapters_book_id_idx
  on public.read_chapters (book_id);

-- ---------------------------------------------------------------------------
-- Row-level security: a user can only see/modify their own rows.
-- ---------------------------------------------------------------------------
alter table public.library_entries enable row level security;
alter table public.read_chapters   enable row level security;

drop policy if exists "library_entries select own" on public.library_entries;
drop policy if exists "library_entries insert own" on public.library_entries;
drop policy if exists "library_entries update own" on public.library_entries;
drop policy if exists "library_entries delete own" on public.library_entries;

create policy "library_entries select own"
  on public.library_entries for select
  using (user_id = auth.uid());

create policy "library_entries insert own"
  on public.library_entries for insert
  with check (user_id = auth.uid());

create policy "library_entries update own"
  on public.library_entries for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "library_entries delete own"
  on public.library_entries for delete
  using (user_id = auth.uid());

drop policy if exists "read_chapters select own" on public.read_chapters;
drop policy if exists "read_chapters insert own" on public.read_chapters;
drop policy if exists "read_chapters update own" on public.read_chapters;
drop policy if exists "read_chapters delete own" on public.read_chapters;

create policy "read_chapters select own"
  on public.read_chapters for select
  using (user_id = auth.uid());

create policy "read_chapters insert own"
  on public.read_chapters for insert
  with check (user_id = auth.uid());

create policy "read_chapters update own"
  on public.read_chapters for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "read_chapters delete own"
  on public.read_chapters for delete
  using (user_id = auth.uid());
