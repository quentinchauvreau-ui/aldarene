create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.aldarene_games (
  id uuid primary key default extensions.gen_random_uuid(),
  room_code text not null unique check (room_code ~ '^[A-Z0-9]{8}$'),
  host_token_hash text not null,
  state jsonb not null,
  hall_of_fame jsonb not null default '[]'::jsonb,
  version bigint not null default 1,
  status text not null default 'active' check (status in ('active', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists private.aldarene_seats (
  game_id uuid not null references public.aldarene_games(id) on delete cascade,
  player_id text not null,
  token_hash text not null,
  created_at timestamptz not null default now(),
  primary key (game_id, player_id),
  unique (game_id, token_hash)
);

create table if not exists private.aldarene_edges (
  a text not null,
  b text not null,
  primary key (a, b),
  check (a <> b)
);

create table if not exists private.aldarene_bonuses (
  territory_id text primary key,
  attack_bonus numeric not null default 0,
  defense_bonus numeric not null default 0
);

truncate table private.aldarene_edges;
insert into private.aldarene_edges (a, b)
select split_part(edge, '-', 1), split_part(edge, '-', 2)
from unnest(string_to_array(
  'cdb-fro,cdb-pao,cdb-bso,fro-pic,fro-pao,fro-bdg,pic-vdl,pic-grb,pic-bdg,pic-chr,pic-mro,vdl-hfj,vdl-grb,vdl-ffr,vdl-pdf,vdl-hha,hfj-cog,hfj-hha,lge-cog,lge-sac,lge-rda,pao-bdg,pao-bso,pao-gpe,pao-ppe,grb-ffr,grb-hpt,grb-mro,cog-mnt,cog-hha,bdg-gpe,bdg-chr,ffr-pdf,mnt-hha,mnt-sac,mnt-pdv,bso-tdg,bso-ppe,gpe-ron,gpe-ppe,gpe-chr,gpe-vda,tdg-cal,tdg-cbr,ron-syn,ron-pgr,ron-ppe,ron-vda,lam-pgr,lam-cbr,lam-fgr,syn-pgr,syn-fgr,syn-vig,syn-vda,syn-cac,cal-pgr,cal-cbr,cal-ppe,pgr-cbr,pgr-ppe,pgr-fgr,fgr-cac,chr-clv,chr-mro,chr-vda,aur-vig,aur-ble,aur-hpt,aur-clv,aur-mro,pdf-vdo,pdf-hpt,pdf-hha,vig-ble,vig-gas,vig-clv,vig-vda,vig-cac,ble-vdo,ble-gas,ble-hpt,ble-dou,ble-vve,vdo-hpt,vdo-dou,vdo-hha,vdo-pdv,vdo-gdc,vdo-ter,gas-cac,gas-sol,gas-vve,hpt-mro,clv-mro,clv-vda,dou-vve,dou-mir,dou-ter,dou-vba,hha-pdv,sac-rda,sac-car,sac-pdv,sac-pdo,rda-fda,rda-pdo,mam-fda,mam-cdl,mam-pdo,mam-tds,car-tro,car-pdv,car-pdo,car-gdc,tro-cdl,tro-gdc,tro-rbr,pdv-gdc,fda-tds,cdl-pdo,cdl-tds,gdc-ter,gdc-rbr,cac-sol,cac-bdc,sol-bdc,sol-ado,vve-mir,vve-ado,mir-ado,mir-vba,cap-oli,cap-ter,cap-vba,oli-ter,oli-rbr,ter-vba,ter-rbr,pep-cdn,pep-slg,cdn-dch,cdn-slg,cdn-pal,sab-oas,sab-dch,sab-cbl,sab-pal,oas-kes,oas-vdr,oas-pam,oas-cbl,kes-pam,kes-pds,dch-slg,dch-cbl,dch-pal,vdr-pam,vdr-cbl,pam-pds,iac-idc,iac-roc,roc-per,per-bri,idc-per,iac-tdg,idc-lam,per-pep,bri-pep,sol-cdn,mir-cdn,cap-sab,oli-oas,idp-iac,idp-tdg,ive-per,ive-pep,ddm-bri,ddm-pep,cdl-kes,ecb-bri,ecb-ddm,idh-ive,idh-pep',
  ','
)) as edge;

truncate table private.aldarene_bonuses;
insert into private.aldarene_bonuses (territory_id, attack_bonus, defense_bonus) values
  ('pic', 0, .30), ('tdg', 0, .25), ('aur', 0, .25), ('rda', 0, .30),
  ('kes', 0, .30), ('tds', 0, .25), ('ecb', 0, .20), ('hfj', .20, 0),
  ('hha', .20, 0), ('cap', .25, 0), ('pep', .20, 0);

alter table public.aldarene_games enable row level security;
revoke all on table public.aldarene_games from public, anon, authenticated;

create or replace function private.aldarene_token_hash(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
$$;

create or replace function private.aldarene_html_escape(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(replace(replace(coalesce(p_value, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$$;

create or replace function public.aldarene_create_game(
  p_state jsonb,
  p_hall_of_fame jsonb,
  p_host_token text,
  p_player_tokens jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game public.aldarene_games%rowtype;
  v_code text;
  v_player jsonb;
  v_player_id text;
  v_token text;
  v_attempt int;
begin
  if jsonb_typeof(p_state -> 'players') <> 'array' or jsonb_typeof(p_state -> 'terr') <> 'object' then
    raise exception 'État de partie invalide.';
  end if;
  if length(coalesce(p_host_token, '')) < 32 then raise exception 'Jeton animateur invalide.'; end if;

  for v_attempt in 1..8 loop
    v_code := upper(substr(translate(encode(extensions.gen_random_bytes(9), 'base64'), '/+=', 'XYZ'), 1, 8));
    begin
      insert into public.aldarene_games (room_code, host_token_hash, state, hall_of_fame)
      values (v_code, private.aldarene_token_hash(p_host_token), p_state, coalesce(p_hall_of_fame, '[]'::jsonb))
      returning * into v_game;
      exit;
    exception when unique_violation then
      if v_attempt = 8 then raise exception 'Impossible de créer un code de partie.'; end if;
    end;
  end loop;

  for v_player in select value from jsonb_array_elements(p_state -> 'players') loop
    v_player_id := v_player ->> 'id';
    v_token := p_player_tokens ->> v_player_id;
    if v_player_id is null or length(coalesce(v_token, '')) < 32 then
      raise exception 'Jeton joueur manquant pour %.', coalesce(v_player_id, '?');
    end if;
    insert into private.aldarene_seats (game_id, player_id, token_hash)
    values (v_game.id, v_player_id, private.aldarene_token_hash(v_token));
  end loop;

  return jsonb_build_object('room_code', v_game.room_code, 'version', v_game.version);
end;
$$;

create or replace function public.aldarene_game_snapshot(p_room_code text, p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game public.aldarene_games%rowtype;
  v_hash text := private.aldarene_token_hash(coalesce(p_access_token, ''));
  v_role text;
  v_player_id text;
begin
  select * into v_game from public.aldarene_games
  where room_code = upper(p_room_code) and status = 'active';
  if not found then raise exception 'Partie introuvable.'; end if;

  if v_hash = v_game.host_token_hash then
    v_role := 'host';
  else
    select player_id into v_player_id from private.aldarene_seats
    where game_id = v_game.id and token_hash = v_hash;
    if not found then raise exception 'Invitation invalide ou expirée.'; end if;
    v_role := 'player';
  end if;

  return jsonb_build_object(
    'state', v_game.state,
    'hall_of_fame', v_game.hall_of_fame,
    'version', v_game.version,
    'role', v_role,
    'player_id', v_player_id,
    'updated_at', v_game.updated_at
  );
end;
$$;

create or replace function public.aldarene_host_replace_game(
  p_room_code text,
  p_host_token text,
  p_expected_version bigint,
  p_state jsonb,
  p_hall_of_fame jsonb,
  p_player_tokens jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game public.aldarene_games%rowtype;
  v_player jsonb;
  v_player_id text;
  v_token text;
begin
  select * into v_game from public.aldarene_games
  where room_code = upper(p_room_code) and status = 'active' for update;
  if not found then raise exception 'Partie introuvable.'; end if;
  if private.aldarene_token_hash(coalesce(p_host_token, '')) <> v_game.host_token_hash then
    raise exception 'Accès animateur refusé.';
  end if;
  if v_game.version <> p_expected_version then raise exception 'CONFLIT_VERSION'; end if;
  if jsonb_typeof(p_state -> 'players') <> 'array' or jsonb_typeof(p_state -> 'terr') <> 'object' then
    raise exception 'État de partie invalide.';
  end if;

  delete from private.aldarene_seats s
  where s.game_id = v_game.id
    and not exists (select 1 from jsonb_array_elements(p_state -> 'players') p where p ->> 'id' = s.player_id);

  for v_player in select value from jsonb_array_elements(p_state -> 'players') loop
    v_player_id := v_player ->> 'id';
    v_token := p_player_tokens ->> v_player_id;
    if length(coalesce(v_token, '')) < 32 then raise exception 'Invitation manquante pour %.', v_player_id; end if;
    insert into private.aldarene_seats (game_id, player_id, token_hash)
    values (v_game.id, v_player_id, private.aldarene_token_hash(v_token))
    on conflict (game_id, player_id) do update set token_hash = excluded.token_hash;
  end loop;

  update public.aldarene_games
  set state = p_state,
      hall_of_fame = coalesce(p_hall_of_fame, '[]'::jsonb),
      version = version + 1,
      updated_at = now()
  where id = v_game.id
  returning version, updated_at into v_game.version, v_game.updated_at;

  return jsonb_build_object('version', v_game.version, 'updated_at', v_game.updated_at);
end;
$$;

create or replace function public.aldarene_perform_action(
  p_room_code text,
  p_player_token text,
  p_expected_version bigint,
  p_action jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game public.aldarene_games%rowtype;
  v_state jsonb;
  v_player_id text;
  v_player jsonb;
  v_player_index int;
  v_daily jsonb;
  v_type text := p_action ->> 'type';
  v_target text := p_action ->> 'target';
  v_origin text := p_action ->> 'origin';
  v_amount bigint := coalesce((p_action ->> 'amount')::bigint, 0);
  v_cell jsonb;
  v_from jsonb;
  v_owner text;
  v_week int := 0;
  v_start_season int;
  v_season int;
  v_limit int;
  v_used int;
  v_tithe numeric;
  v_back bigint;
  v_stolen bigint;
  v_owned int;
  v_attack_bonus numeric := 0;
  v_defense_bonus numeric := 0;
  v_attack bigint;
  v_defense bigint;
  v_survivors bigint;
  v_message text;
begin
  select * into v_game from public.aldarene_games
  where room_code = upper(p_room_code) and status = 'active' for update;
  if not found then raise exception 'Partie introuvable.'; end if;
  if v_game.version <> p_expected_version then raise exception 'CONFLIT_VERSION'; end if;

  select player_id into v_player_id from private.aldarene_seats
  where game_id = v_game.id
    and token_hash = private.aldarene_token_hash(coalesce(p_player_token, ''));
  if not found then raise exception 'Accès joueur refusé.'; end if;

  v_state := v_game.state;
  if v_state ->> 'phase' <> 'war' then raise exception 'La guerre n''est pas encore déclarée.'; end if;

  select value, (ordinality - 1)::int into v_player, v_player_index
  from jsonb_array_elements(v_state -> 'players') with ordinality
  where value ->> 'id' = v_player_id;
  if not found then raise exception 'Maison introuvable.'; end if;

  select coalesce(max((value ->> 'num')::int), 0) into v_week
  from jsonb_array_elements(coalesce(v_state -> 'weeks', '[]'::jsonb));
  v_start_season := coalesce((v_state #>> '{settings,startSeason}')::int, 0);
  v_season := mod(v_start_season + floor((greatest(1, v_week) - 1) / 4.0)::int, 4);
  v_daily := coalesce(v_player -> 'daily', '{}'::jsonb);
  if v_daily ->> 'date' <> current_date::text then
    v_daily := jsonb_build_object('date', current_date::text, 'atk', 0, 'rnf', 0, 'wdr', 0);
  end if;

  if v_target is null or not exists (
    select 1 from private.aldarene_edges where a = v_target or b = v_target
  ) then raise exception 'Région inconnue.'; end if;

  v_cell := coalesce(v_state #> array['terr', v_target], '{"owner":null,"troops":0}'::jsonb);
  v_owner := nullif(v_cell ->> 'owner', '');
  select count(*) into v_owned from jsonb_each(coalesce(v_state -> 'terr', '{}'::jsonb))
  where value ->> 'owner' = v_player_id;

  if v_type in ('reinforce', 'deploy') then
    if v_amount < 1 or v_amount > coalesce((v_player ->> 'reserve')::bigint, 0) then
      raise exception 'Nombre de soldats invalide.';
    end if;
    if v_type = 'reinforce' then
      if v_owner is distinct from v_player_id then raise exception 'Cette région ne vous appartient pas.'; end if;
      v_limit := coalesce((v_state #>> '{settings,maxRnf}')::int, 3);
      v_used := coalesce((v_daily ->> 'rnf')::int, 0);
      if v_limit > 0 and v_used >= v_limit then raise exception 'Quota de renforts atteint.'; end if;
      v_daily := jsonb_set(v_daily, '{rnf}', to_jsonb(v_used + 1));
      v_cell := jsonb_build_object('owner', v_player_id, 'troops', coalesce((v_cell ->> 'troops')::bigint, 0) + v_amount);
      v_message := '🛡 ' || private.aldarene_html_escape(v_player ->> 'faction') || ' renforce ' || v_target || ' (+' || v_amount || ').';
    else
      if v_owned <> 0 or v_owner is not null then raise exception 'Débarquement impossible.'; end if;
      v_cell := jsonb_build_object('owner', v_player_id, 'troops', v_amount);
      v_message := '⚑ ' || private.aldarene_html_escape(v_player ->> 'faction') || ' débarque en ' || v_target || ' (' || v_amount || ' soldats).';
    end if;
    v_player := jsonb_set(v_player, '{reserve}', to_jsonb((v_player ->> 'reserve')::bigint - v_amount));
    v_player := jsonb_set(v_player, '{daily}', v_daily);

  elsif v_type = 'withdraw' then
    if v_owner is distinct from v_player_id then raise exception 'Cette région ne vous appartient pas.'; end if;
    if v_amount < 1 or v_amount > coalesce((v_cell ->> 'troops')::bigint, 0) then raise exception 'Rappel invalide.'; end if;
    v_limit := coalesce((v_state #>> '{settings,maxWdr}')::int, 2);
    v_used := coalesce((v_daily ->> 'wdr')::int, 0);
    if v_limit > 0 and v_used >= v_limit then raise exception 'Quota de rappels atteint.'; end if;
    v_daily := jsonb_set(v_daily, '{wdr}', to_jsonb(v_used + 1));
    v_tithe := coalesce((v_state #>> '{settings,withdrawTithe}')::numeric, 10);
    if v_season = 3 then v_tithe := round(v_tithe / 2); end if;
    v_back := floor(v_amount * (1 - v_tithe / 100));
    if (v_cell ->> 'troops')::bigint = v_amount then
      v_cell := '{"owner":null,"troops":0}'::jsonb;
    else
      v_cell := jsonb_build_object('owner', v_player_id, 'troops', (v_cell ->> 'troops')::bigint - v_amount);
    end if;
    v_player := jsonb_set(v_player, '{reserve}', to_jsonb((v_player ->> 'reserve')::bigint + v_back));
    v_player := jsonb_set(v_player, '{daily}', v_daily);
    v_message := '↩ ' || private.aldarene_html_escape(v_player ->> 'faction') || ' rappelle ' || v_amount || ' soldats de ' || v_target || '.';

  elsif v_type = 'attack' then
    if v_origin is null then raise exception 'Origine manquante.'; end if;
    if not exists (select 1 from private.aldarene_edges where (a = v_origin and b = v_target) or (a = v_target and b = v_origin)) then
      raise exception 'Ces régions ne sont pas voisines.';
    end if;
    v_from := coalesce(v_state #> array['terr', v_origin], '{}'::jsonb);
    if v_from ->> 'owner' is distinct from v_player_id then raise exception 'L''armée d''origine ne vous appartient pas.'; end if;
    if v_owner is not distinct from v_player_id then raise exception 'Vous ne pouvez pas attaquer vos terres.'; end if;
    if v_amount < 1 or v_amount >= coalesce((v_from ->> 'troops')::bigint, 0) then raise exception 'Effectif d''assaut invalide.'; end if;
    v_limit := coalesce((v_state #>> '{settings,maxAtk}')::int, 3);
    if v_season = 2 and v_limit > 0 then v_limit := v_limit + 1; end if;
    v_used := coalesce((v_daily ->> 'atk')::int, 0);
    if v_limit > 0 and v_used >= v_limit then raise exception 'Quota d''assauts atteint.'; end if;
    v_daily := jsonb_set(v_daily, '{atk}', to_jsonb(v_used + 1));
    v_from := jsonb_set(v_from, '{troops}', to_jsonb((v_from ->> 'troops')::bigint - v_amount));
    v_state := jsonb_set(v_state, array['terr', v_origin], v_from, true);
    if v_owner is null then
      v_cell := jsonb_build_object('owner', v_player_id, 'troops', coalesce((v_cell ->> 'troops')::bigint, 0) + v_amount);
      v_message := '⚑ ' || private.aldarene_html_escape(v_player ->> 'faction') || ' occupe ' || v_target || ' depuis ' || v_origin || '.';
    else
      select coalesce(attack_bonus, 0) into v_attack_bonus from private.aldarene_bonuses where territory_id = v_origin;
      if not found then v_attack_bonus := 0; end if;
      select coalesce(defense_bonus, 0) into v_defense_bonus from private.aldarene_bonuses where territory_id = v_target;
      if not found then v_defense_bonus := 0; end if;
      if v_season = 1 then v_defense_bonus := v_defense_bonus + .15; end if;
      v_attack := floor(v_amount * (1 + v_attack_bonus));
      v_defense := ceil((v_cell ->> 'troops')::bigint * (1 + v_defense_bonus));
      if v_attack > v_defense then
        v_survivors := greatest(1, least(v_amount, v_attack - v_defense));
        v_cell := jsonb_build_object('owner', v_player_id, 'troops', v_survivors);
        v_message := '⚔ ' || private.aldarene_html_escape(v_player ->> 'faction') || ' conquiert ' || v_target || ' depuis ' || v_origin || '.';
      elsif v_attack = v_defense then
        v_cell := '{"owner":null,"troops":0}'::jsonb;
        v_message := '⚔ Anéantissement mutuel en ' || v_target || '.';
      else
        v_cell := jsonb_set(v_cell, '{troops}', to_jsonb(greatest(1, ceil((v_defense - v_attack) / (1 + v_defense_bonus))::bigint)));
        v_message := '⚔ L''assaut de ' || private.aldarene_html_escape(v_player ->> 'faction') || ' échoue en ' || v_target || '.';
      end if;
    end if;
    v_player := jsonb_set(v_player, '{daily}', v_daily);

  elsif v_type = 'theft' then
    if v_owner is null or v_owner = v_player_id then raise exception 'Cible de larcin invalide.'; end if;
    if coalesce((v_player ->> 'lastTheftWeek')::int, -1) >= v_week then raise exception 'Larcin déjà utilisé cette semaine.'; end if;
    v_stolen := greatest(1, floor((v_cell ->> 'troops')::bigint * .15));
    if (v_cell ->> 'troops')::bigint <= v_stolen then
      v_cell := '{"owner":null,"troops":0}'::jsonb;
    else
      v_cell := jsonb_set(v_cell, '{troops}', to_jsonb((v_cell ->> 'troops')::bigint - v_stolen));
    end if;
    v_player := jsonb_set(v_player, '{reserve}', to_jsonb((v_player ->> 'reserve')::bigint + v_stolen));
    v_player := jsonb_set(v_player, '{lastTheftWeek}', to_jsonb(v_week));
    v_message := '🗡 Les espions de ' || private.aldarene_html_escape(v_player ->> 'faction') || ' dérobent ' || v_stolen || ' soldats en ' || v_target || '.';
  else
    raise exception 'Action inconnue.';
  end if;

  v_state := jsonb_set(v_state, array['terr', v_target], v_cell, true);
  v_state := jsonb_set(v_state, array['players', v_player_index::text], v_player, false);
  v_state := jsonb_set(v_state, '{log}', jsonb_build_array(jsonb_build_object('w', v_week, 'msg', v_message)) || coalesce(v_state -> 'log', '[]'::jsonb));

  update public.aldarene_games
  set state = v_state, version = version + 1, updated_at = now()
  where id = v_game.id
  returning version, updated_at into v_game.version, v_game.updated_at;

  return jsonb_build_object(
    'state', v_state,
    'hall_of_fame', v_game.hall_of_fame,
    'version', v_game.version,
    'role', 'player',
    'player_id', v_player_id,
    'updated_at', v_game.updated_at
  );
end;
$$;

revoke all on function public.aldarene_create_game(jsonb, jsonb, text, jsonb) from public;
revoke all on function public.aldarene_game_snapshot(text, text) from public;
revoke all on function public.aldarene_host_replace_game(text, text, bigint, jsonb, jsonb, jsonb) from public;
revoke all on function public.aldarene_perform_action(text, text, bigint, jsonb) from public;

grant execute on function public.aldarene_create_game(jsonb, jsonb, text, jsonb) to anon, authenticated;
grant execute on function public.aldarene_game_snapshot(text, text) to anon, authenticated;
grant execute on function public.aldarene_host_replace_game(text, text, bigint, jsonb, jsonb, jsonb) to anon, authenticated;
grant execute on function public.aldarene_perform_action(text, text, bigint, jsonb) to anon, authenticated;
