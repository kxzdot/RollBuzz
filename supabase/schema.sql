-- Выполните этот файл целиком в Supabase: SQL Editor → New query → Run.
-- Его можно запускать повторно, ничего не сломается.

-- ============ 1. Таблицы ============

-- Сотрудники (создаётся автоматически при регистрации)
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  login      text not null,
  full_name  text not null,
  created_at timestamptz not null default now()
);

-- Настройки (здесь хранится код регистрации; из приложения эта таблица недоступна)
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);

-- Рулоны
create table if not exists public.rolls (
  id         text primary key check (id ~ '^[0-9]{1,20}$'),  -- номер рулона, только цифры, повторов быть не может
  rack       text not null,                                   -- номер стеллажа
  floor      text not null default '',                        -- этаж стеллажа (пусто, если этаж один)
  fabric     text not null default '',                        -- ткань
  color      text not null default '',                        -- цвет
  deleted    boolean not null default false,                  -- true: рулон лежит во вкладке «Удалённые»
  deleted_at timestamptz,
  deleted_by_name text,                                       -- кто удалил
  updated_at timestamptz not null default now(),
  updated_by uuid,
  updated_by_name text                                        -- кто изменил последним
);

-- Если таблица rolls уже была создана раньше, добавим недостающие колонки
alter table public.rolls add column if not exists floor text not null default '';
alter table public.rolls add column if not exists deleted_by_name text;
alter table public.rolls add column if not exists updated_by uuid;
alter table public.rolls add column if not exists updated_by_name text;

-- История изменений рулонов
create table if not exists public.roll_log (
  id      bigint generated always as identity primary key,
  roll_id text not null,
  action  text not null,            -- add, edit, delete, restore, purge
  by_name text not null,            -- кто сделал
  details text not null default '', -- что изменилось
  at      timestamptz not null default now()
);
create index if not exists roll_log_roll_idx on public.roll_log (roll_id, at desc);

-- ============ 2. Права доступа ============
-- Работать с рулонами могут только вошедшие сотрудники.

alter table public.profiles     enable row level security;
alter table public.app_settings enable row level security;
alter table public.rolls        enable row level security;
alter table public.roll_log     enable row level security;

drop policy if exists "sklad_access" on public.rolls;       -- старая открытая политика, если была
drop policy if exists "rolls_all" on public.rolls;
create policy "rolls_all" on public.rolls
  for all to authenticated using (true) with check (true);

drop policy if exists "profiles_self" on public.profiles;
create policy "profiles_self" on public.profiles
  for select to authenticated using (id = auth.uid());

drop policy if exists "log_read" on public.roll_log;
create policy "log_read" on public.roll_log
  for select to authenticated using (true);

revoke all on public.app_settings from anon, authenticated;

-- ============ 3. Регистрация только по коду ============

create or replace function public.check_signup_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare need text;
begin
  select value into need from public.app_settings where key = 'signup_code';
  if need is null or need = '' then
    raise exception 'Код регистрации не задан';
  end if;
  if coalesce(new.raw_user_meta_data->>'code', '') <> need then
    raise exception 'Неверный код регистрации';
  end if;
  return new;
end $$;

drop trigger if exists sklad_check_signup on auth.users;
create trigger sklad_check_signup before insert on auth.users
  for each row execute function public.check_signup_code();

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, login, full_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'login', ''),
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), 'Без имени')
  );
  return new;
end $$;

drop trigger if exists sklad_new_user on auth.users;
create trigger sklad_new_user after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============ 4. Кто и что изменил (заполняется автоматически) ============

create or replace function public.place_text(p_rack text, p_floor text) returns text
language sql immutable as $$
  select coalesce(nullif(p_rack, ''), '—') || ' стеллаж'
         || case when coalesce(p_floor, '') <> '' then ' (' || p_floor || ' этаж)' else '' end
$$;

create or replace function public.rolls_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text;
  act text;
  det text := '';
begin
  select full_name into who from public.profiles where id = auth.uid();
  who := coalesce(who, 'Неизвестный');

  new.updated_at      := now();
  new.updated_by      := auth.uid();
  new.updated_by_name := who;

  if tg_op = 'INSERT' then
    new.deleted         := false;
    new.deleted_at      := null;
    new.deleted_by_name := null;
    insert into public.roll_log (roll_id, action, by_name, details)
    values (new.id, 'add', who, public.place_text(new.rack, new.floor));
    return new;
  end if;

  -- обновление
  if new.deleted and not old.deleted then
    act := 'delete';
    new.deleted_at := now();
    new.deleted_by_name := who;
  elsif old.deleted and not new.deleted then
    act := 'restore';
    new.deleted_at := null;
    new.deleted_by_name := null;
  else
    act := 'edit';
    new.deleted_at := old.deleted_at;
    new.deleted_by_name := old.deleted_by_name;
  end if;

  if new.rack is distinct from old.rack or new.floor is distinct from old.floor then
    det := 'место: ' || public.place_text(old.rack, old.floor) || ' → ' || public.place_text(new.rack, new.floor);
  end if;
  if new.fabric is distinct from old.fabric then
    det := det || case when det <> '' then '; ' else '' end
           || 'ткань: ' || coalesce(nullif(old.fabric, ''), '—') || ' → ' || coalesce(nullif(new.fabric, ''), '—');
  end if;
  if new.color is distinct from old.color then
    det := det || case when det <> '' then '; ' else '' end
           || 'цвет: ' || coalesce(nullif(old.color, ''), '—') || ' → ' || coalesce(nullif(new.color, ''), '—');
  end if;

  if act = 'edit' and det = '' then
    -- ничего не изменилось: не трогаем «кто и когда менял»
    new.updated_at      := old.updated_at;
    new.updated_by      := old.updated_by;
    new.updated_by_name := old.updated_by_name;
  else
    insert into public.roll_log (roll_id, action, by_name, details)
    values (new.id, act, who, det);
  end if;
  return new;
end $$;

drop trigger if exists rolls_stamp_trg on public.rolls;
create trigger rolls_stamp_trg before insert or update on public.rolls
  for each row execute function public.rolls_stamp();

create or replace function public.rolls_log_purge() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text;
begin
  select full_name into who from public.profiles where id = auth.uid();
  insert into public.roll_log (roll_id, action, by_name, details)
  values (old.id, 'purge', coalesce(who, 'Неизвестный'), public.place_text(old.rack, old.floor));
  return old;
end $$;

drop trigger if exists rolls_purge_trg on public.rolls;
create trigger rolls_purge_trg before delete on public.rolls
  for each row execute function public.rolls_log_purge();

-- ============ 5. Код регистрации ============
-- Код задаётся отдельной командой, см. README (шаг 3). Пока код не задан, зарегистрироваться нельзя.
