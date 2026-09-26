-- =====================================================================
--  PES COSTA RICA · base de datos
--  Pégalo completo en Supabase > SQL Editor > New query > Run.
--  Se puede volver a ejecutar sin perder datos.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- tablas ----------
-- Todo el contenido (jugadores, partidos, torneos, anuncios, álbumes,
-- historial de campeones y ajustes) vive en "items", un registro por fila.
create table if not exists public.items (
  coll        text not null,
  id          text not null,
  data        jsonb not null,
  created_at  timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp(),
  updated_by  text,
  primary key (coll, id)
);

-- Copia de cada versión anterior: ningún cambio sobrescribe el pasado.
create table if not exists public.item_versions (
  n          bigserial primary key,
  coll       text not null,
  id         text not null,
  op         text not null,
  data       jsonb not null,
  changed_at timestamptz not null default clock_timestamp(),
  changed_by text
);
create index if not exists item_versions_idx on public.item_versions (coll, id);

create table if not exists public.accounts (
  id_lower   text primary key,
  player_id  text not null,
  pass_hash  text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.sessions (
  token      text primary key,
  player_id  text not null,
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);

create table if not exists public.activity_log (
  n   bigserial primary key,
  at  timestamptz not null default now(),
  by  text,
  txt text not null
);

create table if not exists public.traffic (
  id         text primary key,
  day        date not null,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
create index if not exists traffic_day_idx on public.traffic (day);

create table if not exists public.upload_tickets (
  name    text primary key,
  expires timestamptz not null
);

create table if not exists public.meta (
  k text primary key,
  v bigint not null
);
insert into public.meta (k, v) values ('rev', 1) on conflict do nothing;

-- Nadie entra a las tablas directamente: todo pasa por las funciones de abajo.
alter table public.items          enable row level security;
alter table public.item_versions  enable row level security;
alter table public.accounts       enable row level security;
alter table public.sessions       enable row level security;
alter table public.activity_log   enable row level security;
alter table public.traffic        enable row level security;
alter table public.upload_tickets enable row level security;
alter table public.meta           enable row level security;
revoke all on public.items, public.item_versions, public.accounts, public.sessions,
  public.activity_log, public.traffic, public.upload_tickets, public.meta
  from anon, authenticated;

-- ---------- historial automático de cambios ----------
create or replace function public.pescr_keep_version() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if old.data is distinct from new.data then
      insert into item_versions (coll, id, op, data, changed_by)
      values (old.coll, old.id, 'update', old.data, new.updated_by);
    end if;
    return new;
  else
    insert into item_versions (coll, id, op, data, changed_by)
    values (old.coll, old.id, 'delete', old.data, old.updated_by);
    return old;
  end if;
end $$;

drop trigger if exists pescr_items_versions on public.items;
create trigger pescr_items_versions
  before update or delete on public.items
  for each row execute function public.pescr_keep_version();

-- ---------- ayudantes internos ----------
create or replace function public.pescr_me(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  if p_token is null or p_token = '' then return null; end if;
  update sessions set last_seen = now()
   where token = p_token and last_seen > now() - interval '90 days'
   returning player_id into pid;
  if pid is null then return null; end if;
  -- una cuenta dada de baja ya no puede entrar
  if exists (select 1 from items where coll = 'players' and id = pid
             and coalesce(data->>'active', 'true') = 'false') then
    delete from sessions where token = p_token;
    return null;
  end if;
  return pid;
end $$;

create or replace function public.pescr_is_admin(pid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from items where coll = 'players' and id = pid
                 and data->>'role' = 'admin' and coalesce(data->>'active','true') <> 'false');
$$;

create or replace function public.pescr_bump() returns bigint
language sql security definer set search_path = public as $$
  update meta set v = v + 1 where k = 'rev' returning v;
$$;

create or replace function public.pescr_new_token(pid text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  insert into sessions (token, player_id) values (t, pid);
  delete from sessions where last_seen < now() - interval '90 days';
  return t;
end $$;

create or replace function public.pescr_put(p_coll text, p_id text, p_data jsonb, p_by text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into items (coll, id, data, updated_by) values (p_coll, p_id, p_data, p_by)
  on conflict (coll, id) do update
    set data = excluded.data, updated_at = clock_timestamp(), updated_by = excluded.updated_by
    where items.data is distinct from excluded.data;
end $$;

-- ---------- registro, entrada y salida ----------
create or replace function public.pescr_register(body jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id   text := regexp_replace(btrim(coalesce(body->>'id','')), '\s+', ' ', 'g');
  v_pass text := coalesce(body->>'pass','');
  v_nat  text := left(coalesce(nullif(body->>'nationality',''), 'Costa Rica'), 60);
  v_ph   text := body->>'photo';
  ex     record;
  first_admin boolean;
  claimed boolean := false;
  pdata  jsonb;
begin
  if v_id !~ '^[A-Za-z0-9_.\- ]{3,24}$' then return jsonb_build_object('error','id'); end if;
  if length(v_pass) < 6 or length(v_pass) > 72 then return jsonb_build_object('error','pass'); end if;
  if v_ph is not null and (v_ph !~ '^data:image/(jpeg|png|webp);base64,' or length(v_ph) > 200000) then v_ph := null; end if;
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from accounts where id_lower = lower(v_id)) then
    return jsonb_build_object('error','exists');
  end if;
  -- solo si no hay ningún administrador definido, el primero en inscribirse lo es
  first_admin := not exists (
    select 1 from items i where i.coll = 'players' and i.data->>'role' = 'admin'
       and coalesce(i.data->>'active','true') <> 'false');
  select * into ex from items where coll = 'players' and lower(id) = lower(v_id) limit 1;
  if found then
    -- el ID venía de datos importados o de un torneo externo: reclama su historial
    claimed := true;
    v_id := ex.id;
    pdata := ex.data || jsonb_build_object('guest', false, 'pending', false, 'nationality', v_nat,
               'joined', to_char(now() at time zone 'America/Costa_Rica','YYYY-MM-DD'), 'active', true);
    if v_ph is not null then pdata := pdata || jsonb_build_object('photo', v_ph); end if;
    if first_admin then pdata := pdata || '{"role":"admin"}'; end if;
  else
    pdata := jsonb_build_object('id', v_id, 'role', case when first_admin then 'admin' else 'player' end,
               'photo', v_ph, 'nationality', v_nat,
               'joined', to_char(now() at time zone 'America/Costa_Rica','YYYY-MM-DD'), 'active', true);
  end if;
  perform pescr_put('players', v_id, pdata, v_id);
  insert into accounts (id_lower, player_id, pass_hash)
  values (lower(v_id), v_id, extensions.crypt(v_pass, extensions.gen_salt('bf', 10)));
  insert into activity_log (by, txt) values (v_id, 'Se inscribió ' || v_id ||
    case when claimed then ' (reclamó su historial)' else '' end ||
    case when first_admin then ' · primer administrador' else '' end);
  perform pescr_bump();
  return jsonb_build_object('token', pescr_new_token(v_id), 'me', v_id, 'claimed', claimed, 'admin', first_admin);
end $$;

create or replace function public.pescr_login(body jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from accounts where id_lower = lower(btrim(coalesce(body->>'id','')));
  if not found or a.pass_hash <> extensions.crypt(coalesce(body->>'pass',''), a.pass_hash) then
    perform pg_sleep(0.4);
    return jsonb_build_object('error','bad');
  end if;
  if exists (select 1 from items where coll='players' and id=a.player_id and coalesce(data->>'active','true')='false') then
    return jsonb_build_object('error','inactive');
  end if;
  return jsonb_build_object('token', pescr_new_token(a.player_id), 'me', a.player_id);
end $$;

create or replace function public.pescr_logout(body jsonb) returns jsonb
language sql security definer set search_path = public as $$
  delete from sessions where token = body->>'token';
  select '{"ok":true}'::jsonb;
$$;

create or replace function public.pescr_set_pass(body jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me text := pescr_me(body->>'token');
  target text := coalesce(nullif(body->>'target',''), me);
  np text := coalesce(body->>'new','');
  a record;
begin
  if me is null then return jsonb_build_object('error','session'); end if;
  if length(np) < 6 or length(np) > 72 then return jsonb_build_object('error','pass'); end if;
  select * into a from accounts where player_id = target;
  if not found then return jsonb_build_object('error','noaccount'); end if;
  if target = me then
    if a.pass_hash <> extensions.crypt(coalesce(body->>'old',''), a.pass_hash) then
      return jsonb_build_object('error','bad');
    end if;
  elsif not pescr_is_admin(me)
     or exists (select 1 from items where coll='players' and id=target and data->>'owner'='true') then
    return jsonb_build_object('error','forbidden');
  end if;
  update accounts set pass_hash = extensions.crypt(np, extensions.gen_salt('bf', 10)) where player_id = target;
  if target <> me then
    delete from sessions where player_id = target;
    insert into activity_log (by, txt) values (me, 'Cambió la contraseña de ' || target);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- leer todo ----------
create or replace function public.pescr_pull(body jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me text := pescr_me(body->>'token');
  cur bigint;
  res jsonb;
begin
  if me is null then return jsonb_build_object('error','session'); end if;
  select v into cur from meta where k = 'rev';
  if (body->>'rev') is not null and (body->>'rev')::bigint = cur then
    return jsonb_build_object('rev', cur, 'same', true, 'me', me);
  end if;
  select coalesce(jsonb_object_agg(coll, arr), '{}'::jsonb) into res from (
    select i.coll, jsonb_agg(
             case when i.coll = 'players'
                  then (i.data - 'pass') || jsonb_build_object('pass', a.player_id is not null)
                  else i.data end
             order by i.created_at, i.id) arr
      from items i left join accounts a on i.coll = 'players' and a.player_id = i.id
     group by i.coll) q;
  res := jsonb_build_object('rev', cur, 'me', me, 'data', res);
  if pescr_is_admin(me) then
    res := res || jsonb_build_object('log', coalesce((select jsonb_agg(jsonb_build_object(
             'ts', (extract(epoch from at) * 1000)::bigint, 'by', by, 'txt', txt) order by n desc)
             from (select * from activity_log order by n desc limit 300) l), '[]'::jsonb));
  end if;
  return res;
end $$;

-- historial de versiones de un registro (solo administradores)
create or replace function public.pescr_versions(body jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me text := pescr_me(body->>'token');
begin
  if me is null or not pescr_is_admin(me) then return jsonb_build_object('error','forbidden'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', changed_at, 'by', changed_by, 'op', op, 'data', data) order by n desc)
    from item_versions where coll = body->>'coll' and id = body->>'id'), '[]'::jsonb);
end $$;

-- ---------- guardar cambios ----------
create or replace function public.pescr_push(body jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me text := pescr_me(body->>'token');
  adm boolean;
  ch jsonb;
  c text; iid text; d jsonb; old jsonb;
  rejected int := 0; applied int := 0;
  regs jsonb; want boolean; had boolean;
  txt text;
begin
  if me is null then return jsonb_build_object('error','session'); end if;
  adm := pescr_is_admin(me);
  for ch in select * from jsonb_array_elements(coalesce(body->'changes','[]'::jsonb)) loop
    c := ch->>'c'; iid := ch->>'id'; d := ch->'d';
    if c is null or iid is null or length(iid) > 80
       or c not in ('players','matches','tournaments','history','announcements','albums','settings') then
      rejected := rejected + 1; continue;
    end if;
    if d is not null and jsonb_typeof(d) <> 'object' then rejected := rejected + 1; continue; end if;
    if d is not null then d := d - 'pass'; end if;
    select data into old from items where coll = c and id = iid;

    if adm then
      if d is null then
        if c = 'players' then rejected := rejected + 1; continue; end if; -- a los jugadores se les da de baja, no se borran
        delete from items where coll = c and id = iid;
      elsif c = 'players' and iid <> me and (old->>'owner') = 'true' then
        rejected := rejected + 1; continue;                            -- nadie más toca al administrador principal
      elsif c = 'players' then
        d := (d - 'owner') || case when (old->>'owner') = 'true' then '{"owner":true,"role":"admin","active":true}'::jsonb else '{}'::jsonb end;
        perform pescr_put(c, iid, d, me);
      else
        perform pescr_put(c, iid, d, me);
      end if;
      applied := applied + 1; continue;
    end if;

    -- ---- miembros normales ----
    if d is null then rejected := rejected + 1; continue; end if;
    if c = 'players' and iid = me and old is not null then
      if (d->>'photo') is not null and ((d->>'photo') !~ '^data:image/(jpeg|png|webp);base64,' or length(d->>'photo') > 200000) then
        rejected := rejected + 1; continue;
      end if;
      perform pescr_put(c, iid, old || jsonb_build_object('photo', d->'photo',
        'nationality', left(coalesce(d->>'nationality', old->>'nationality'), 60)), me);
      applied := applied + 1;
    elsif c = 'matches' and old is null then
      -- reportar un resultado propio: siempre entra como pendiente
      if d->>'reportedBy' = me and (d->>'home' = me or d->>'away' = me) and d->>'home' <> d->>'away'
         and d->>'status' = 'pendiente' and d->>'id' = iid
         and exists (select 1 from items where coll='players' and id = case when d->>'home' = me then d->>'away' else d->>'home' end) then
        perform pescr_put(c, iid, d, me); applied := applied + 1;
      else rejected := rejected + 1; end if;
    elsif c = 'matches' then
      -- cancelar un resultado propio que sigue pendiente
      if old->>'reportedBy' = me and old->>'status' = 'pendiente' and d->>'status' = 'eliminado' then
        perform pescr_put(c, iid, old || jsonb_build_object('status','eliminado','hist', coalesce(d->'hist', old->'hist')), me);
        applied := applied + 1;
      else rejected := rejected + 1; end if;
    elsif c = 'announcements' and old is not null then
      -- inscribirse o salirse de un torneo anunciado
      regs := coalesce(old->'registrants','[]'::jsonb);
      had := regs ? me;
      want := coalesce(d->'registrants','[]'::jsonb) ? me;
      if want and not had and coalesce(old->>'open','true') <> 'false' then
        regs := regs || to_jsonb(me);
      elsif had and not want then
        regs := (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(regs) x where x <> to_jsonb(me));
      end if;
      perform pescr_put(c, iid, old || jsonb_build_object('registrants', regs), me);
      applied := applied + 1;
    else
      rejected := rejected + 1;
    end if;
  end loop;

  for txt in select jsonb_array_elements_text(coalesce(body->'logs','[]'::jsonb)) loop
    insert into activity_log (by, txt) values (me, left(txt, 400));
  end loop;
  delete from activity_log where n < (select max(n) - 5000 from activity_log);

  return jsonb_build_object('rev', case when applied > 0 then pescr_bump() else (select v from meta where k='rev') end,
                            'applied', applied, 'rejected', rejected);
end $$;

-- ---------- fotos de la galería ----------
create or replace function public.pescr_upload_names(body jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me text := pescr_me(body->>'token');
  k int := least(greatest(coalesce((body->>'n')::int, 1), 1), 20);
  out jsonb := '[]'::jsonb; nm text;
begin
  if me is null or not pescr_is_admin(me) then return jsonb_build_object('error','forbidden'); end if;
  delete from upload_tickets where expires < now();
  for i in 1..k loop
    nm := 'g/' || to_char(now(), 'YYYYMM') || '/' || encode(extensions.gen_random_bytes(12), 'hex') || '.jpg';
    insert into upload_tickets (name, expires) values (nm, now() + interval '30 minutes');
    out := out || to_jsonb(nm);
  end loop;
  return jsonb_build_object('names', out);
end $$;

create or replace function public.pescr_ticket_ok(p_name text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  delete from upload_tickets where name = p_name and expires > now();
  return found;
end $$;

-- ---------- tráfico ----------
create or replace function public.pescr_track(body jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me text := pescr_me(body->>'token');
  r jsonb := body->'rec';
  sid text := r->>'id';
  d date;
begin
  if sid is null or length(sid) > 40 or jsonb_typeof(r) <> 'object' or length(r::text) > 4000 then
    return jsonb_build_object('error','bad');
  end if;
  begin d := (r->>'day')::date; exception when others then d := current_date; end;
  if d < current_date - 2 or d > current_date + 1 then d := current_date; end if;
  r := r || jsonb_build_object('u', me, 'v', case when me is not null then 'u:' || me else left(coalesce(r->>'v','anon'), 40) end, 'day', d);
  insert into traffic (id, day, data) values (sid, d, r)
  on conflict (id) do update set data = excluded.data, updated_at = now()
    where traffic.day = excluded.day;
  return '{"ok":true}'::jsonb;
end $$;

create or replace function public.pescr_traffic(body jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me text := pescr_me(body->>'token');
begin
  if me is null or not pescr_is_admin(me) then return jsonb_build_object('error','forbidden'); end if;
  delete from traffic where day < current_date - 400;
  return jsonb_build_object('sessions', coalesce((select jsonb_agg(data) from traffic
    where day >= current_date - least(greatest(coalesce((body->>'days')::int, 30), 1), 366)), '[]'::jsonb));
end $$;

-- ---------- permisos de las funciones ----------
revoke all on function public.pescr_keep_version(), public.pescr_me(text), public.pescr_is_admin(text),
  public.pescr_bump(), public.pescr_new_token(text), public.pescr_put(text, text, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.pescr_register(jsonb), public.pescr_login(jsonb), public.pescr_logout(jsonb),
  public.pescr_set_pass(jsonb), public.pescr_pull(jsonb), public.pescr_push(jsonb), public.pescr_versions(jsonb),
  public.pescr_upload_names(jsonb), public.pescr_track(jsonb), public.pescr_traffic(jsonb),
  public.pescr_ticket_ok(text)
  to anon, authenticated;

-- ---------- almacenamiento de fotos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', true, 6291456, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 6291456, allowed_mime_types = array['image/jpeg'];

drop policy if exists "pescr subir fotos con permiso" on storage.objects;
create policy "pescr subir fotos con permiso" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'fotos' and public.pescr_ticket_ok(name));

-- ---------- administradores de la comunidad ----------
-- Quedan reservados: al inscribirse con estos ID reciben sus permisos.
insert into public.items (coll, id, data, updated_by) values
  ('players', 'Lgsoto92', '{"id":"Lgsoto92","name":"Luis Soto","role":"admin","owner":true,"pending":true,"active":true,"nationality":"Costa Rica","photo":null}', 'instalacion'),
  ('players', 'LMarin',   '{"id":"LMarin","name":"Luis Marin","role":"admin","pending":true,"active":true,"nationality":"Costa Rica","photo":null}', 'instalacion')
on conflict (coll, id) do nothing;

-- Listo. Si ves "Success. No rows returned", todo quedó instalado.
