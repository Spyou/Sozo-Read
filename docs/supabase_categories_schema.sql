-- ---------------------------------------------------------------------------
-- Sync follow-up migrations.
--
-- Paste this into the Supabase SQL editor on top of the existing
-- supabase/schema.sql. Idempotent — every CREATE / ALTER uses
-- IF (NOT) EXISTS so you can re-run it safely.
--
-- Sections:
--   1. library_entries.last_seen_chapter_count  (new-chapter notification baseline)
--   2. library_categories                        (user-defined categories)
--   3. library_entry_categories                  (entry -> category join)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. library_entries.last_seen_chapter_count
--
-- The Flutter ChapterCheckService remembers the chapter count it last saw
-- on each saved book and uses it as the baseline for "new chapter"
-- notifications. We sync the counter so a re-install / second device
-- doesn't fire a fresh notification flood for back-catalogue chapters.
-- ---------------------------------------------------------------------------
alter table public.library_entries
  add column if not exists last_seen_chapter_count integer not null default 0;


-- ---------------------------------------------------------------------------
-- 2. library_categories
--
-- One row per user-defined category (e.g. "Favorites", "Currently Reading").
-- `id` is a client-generated UUID/ULID so two devices can independently
-- mint rows without colliding on auto-increment keys.
-- ---------------------------------------------------------------------------
create table if not exists public.library_categories (
  user_id    uuid        not null references auth.users(id) on delete cascade,
  id         text        not null,
  name       text        not null,
  sort_order integer     not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create index if not exists library_categories_user_sort_idx
  on public.library_categories (user_id, sort_order);

alter table public.library_categories enable row level security;

drop policy if exists "library_categories select own" on public.library_categories;
drop policy if exists "library_categories insert own" on public.library_categories;
drop policy if exists "library_categories update own" on public.library_categories;
drop policy if exists "library_categories delete own" on public.library_categories;

create policy "library_categories select own"
  on public.library_categories for select
  using (user_id = auth.uid());

create policy "library_categories insert own"
  on public.library_categories for insert
  with check (user_id = auth.uid());

create policy "library_categories update own"
  on public.library_categories for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "library_categories delete own"
  on public.library_categories for delete
  using (user_id = auth.uid());


-- ---------------------------------------------------------------------------
-- 3. library_entry_categories
--
-- Join table: an entry can live in zero or more categories. The (source,
-- book) tuple references library_entries.(source_id, book_id) implicitly
-- (no FK — we tolerate orphans because the Flutter side syncs each table
-- independently, so a category-assignment row may briefly arrive before
-- the library_entry row it references).
-- ---------------------------------------------------------------------------
create table if not exists public.library_entry_categories (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  source_id   text        not null,
  book_id     text        not null,
  category_id text        not null,
  added_at    timestamptz not null default now(),
  primary key (user_id, source_id, book_id, category_id)
);

create index if not exists library_entry_categories_category_idx
  on public.library_entry_categories (user_id, category_id);

create index if not exists library_entry_categories_book_idx
  on public.library_entry_categories (user_id, source_id, book_id);

alter table public.library_entry_categories enable row level security;

drop policy if exists "library_entry_categories select own" on public.library_entry_categories;
drop policy if exists "library_entry_categories insert own" on public.library_entry_categories;
drop policy if exists "library_entry_categories update own" on public.library_entry_categories;
drop policy if exists "library_entry_categories delete own" on public.library_entry_categories;

create policy "library_entry_categories select own"
  on public.library_entry_categories for select
  using (user_id = auth.uid());

create policy "library_entry_categories insert own"
  on public.library_entry_categories for insert
  with check (user_id = auth.uid());

create policy "library_entry_categories update own"
  on public.library_entry_categories for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "library_entry_categories delete own"
  on public.library_entry_categories for delete
  using (user_id = auth.uid());
