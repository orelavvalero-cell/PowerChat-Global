-- PowerChat Global: database schema and security policies.
-- Run the whole file once in Supabase Dashboard -> SQL Editor.

begin;

create table if not exists public.profiles (
    user_id uuid primary key references auth.users(id) on delete cascade,
    nickname text not null,
    created_at timestamptz not null default now(),
    last_seen timestamptz not null default now(),
    constraint profiles_nickname_length check (char_length(nickname) between 2 and 24),
    constraint profiles_nickname_trimmed check (nickname = btrim(nickname)),
    constraint profiles_nickname_safe check (nickname !~ '[[:cntrl:]]')
);

create unique index if not exists profiles_nickname_lower_key
    on public.profiles (lower(nickname));

create table if not exists public.messages (
    id bigint generated always as identity primary key,
    user_id uuid not null default auth.uid()
        references public.profiles(user_id) on delete cascade,
    content text not null,
    created_at timestamptz not null default now(),
    constraint messages_content_length check (char_length(content) between 1 and 500),
    constraint messages_content_visible check (btrim(content) <> '')
);

create index if not exists messages_created_at_idx
    on public.messages (created_at desc);

create index if not exists messages_user_created_idx
    on public.messages (user_id, created_at desc);

create table if not exists public.reports (
    id bigint generated always as identity primary key,
    reporter_id uuid not null default auth.uid()
        references auth.users(id) on delete cascade,
    message_id bigint not null references public.messages(id) on delete cascade,
    reason text not null default 'Not specified',
    created_at timestamptz not null default now(),
    constraint reports_reason_length check (char_length(reason) between 1 and 200),
    constraint reports_one_per_user unique (reporter_id, message_id)
);

create table if not exists public.bans (
    user_id uuid primary key references auth.users(id) on delete cascade,
    reason text not null default 'Moderator decision',
    created_at timestamptz not null default now(),
    expires_at timestamptz
);

alter table public.profiles enable row level security;
alter table public.messages enable row level security;
alter table public.reports enable row level security;
alter table public.bans enable row level security;

create or replace function public.chat_is_banned()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.bans
        where user_id = (select auth.uid())
          and (expires_at is null or expires_at > now())
    );
$$;

create or replace function public.chat_can_send()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select
        (select auth.uid()) is not null
        and not public.chat_is_banned()
        and (
            select count(*) < 4
            from public.messages
            where user_id = (select auth.uid())
              and created_at > now() - interval '10 seconds'
        )
        and (
            select count(*) < 20
            from public.messages
            where user_id = (select auth.uid())
              and created_at > now() - interval '1 minute'
        );
$$;

create or replace function public.chat_online_count()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
    select count(*)
    from public.profiles
    where last_seen > now() - interval '45 seconds';
$$;

revoke all on function public.chat_is_banned() from public;
revoke all on function public.chat_can_send() from public;
revoke all on function public.chat_online_count() from public;
grant execute on function public.chat_is_banned() to authenticated;
grant execute on function public.chat_can_send() to authenticated;
grant execute on function public.chat_online_count() to authenticated;

drop policy if exists "Authenticated users can read profiles" on public.profiles;
create policy "Authenticated users can read profiles"
on public.profiles for select
to authenticated
using (true);

drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile"
on public.profiles for insert
to authenticated
with check (
    user_id = (select auth.uid())
    and not public.chat_is_banned()
);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
on public.profiles for update
to authenticated
using (user_id = (select auth.uid()))
with check (
    user_id = (select auth.uid())
    and not public.chat_is_banned()
);

drop policy if exists "Authenticated users can read messages" on public.messages;
create policy "Authenticated users can read messages"
on public.messages for select
to authenticated
using (true);

drop policy if exists "Users can send rate-limited messages" on public.messages;
create policy "Users can send rate-limited messages"
on public.messages for insert
to authenticated
with check (
    user_id = (select auth.uid())
    and public.chat_can_send()
);

drop policy if exists "Users can delete their own messages" on public.messages;
create policy "Users can delete their own messages"
on public.messages for delete
to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "Users can report messages" on public.reports;
create policy "Users can report messages"
on public.reports for insert
to authenticated
with check (reporter_id = (select auth.uid()));

revoke all on public.profiles from anon;
revoke all on public.messages from anon;
revoke all on public.reports from anon;
revoke all on public.bans from anon, authenticated;

grant select, insert, update on public.profiles to authenticated;
grant select, insert, delete on public.messages to authenticated;
grant insert on public.reports to authenticated;
grant usage, select on sequence public.messages_id_seq to authenticated;
grant usage, select on sequence public.reports_id_seq to authenticated;

do $$
begin
    if not exists (
        select 1
        from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'messages'
    ) then
        alter publication supabase_realtime add table public.messages;
    end if;
end
$$;

commit;

-- Moderator examples (run manually in SQL Editor):
-- Ban permanently:
-- insert into public.bans (user_id, reason) values ('USER_UUID', 'Spam')
-- on conflict (user_id) do update set reason = excluded.reason, expires_at = null;
--
-- Unban:
-- delete from public.bans where user_id = 'USER_UUID';
--
-- Remove a message:
-- delete from public.messages where id = 123;

