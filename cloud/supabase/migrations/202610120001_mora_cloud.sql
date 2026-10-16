-- Mora family sync. Apply once in a NEW Supabase project's SQL Editor.
-- Only authenticated household members can read data. Phone tokens are write-only.
begin;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table public.mora_households (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  name text not null check (length(name) between 1 and 100),
  snapshot jsonb not null,
  version bigint not null default 1,
  updated_at timestamptz not null default now()
);
create table public.mora_members (
  household_id uuid not null references public.mora_households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (household_id, user_id)
);
create table public.mora_invitations (
  token_hash bytea primary key,
  household_id uuid not null references public.mora_households(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '7 days'
);
create table public.mora_phone_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash bytea not null unique,
  household_id uuid not null references public.mora_households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  account_id uuid not null,
  label text not null check (length(label) between 1 and 100),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.mora_captures (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.mora_households(id) on delete cascade,
  phone_token_id uuid not null references public.mora_phone_tokens(id),
  event_id uuid not null,
  account_id uuid not null,
  merchant text not null,
  amount_text text not null,
  currency text not null,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  state text not null check (state in ('pending', 'recorded', 'dismissed')),
  transaction_id uuid,
  reason text,
  unique (phone_token_id, event_id)
);
create index mora_captures_daily on public.mora_captures(phone_token_id, created_at);
create index mora_captures_pending on public.mora_captures(household_id, state);
alter table public.mora_households enable row level security;
alter table public.mora_members enable row level security;
alter table public.mora_invitations enable row level security;
alter table public.mora_phone_tokens enable row level security;
alter table public.mora_captures enable row level security;
-- No direct table grants or policies: all operations go through narrowly scoped RPCs.
revoke all on public.mora_households, public.mora_members, public.mora_invitations,
  public.mora_phone_tokens, public.mora_captures from anon, authenticated;

create function public.mora_require_member(p_household_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.mora_members where household_id = p_household_id and user_id = auth.uid()
  ) then raise exception 'Household access denied' using errcode = '42501'; end if;
end $$;

create function public.mora_validate_snapshot(p_snapshot jsonb) returns void
language plpgsql set search_path = '' as $$
declare k text;
begin
  if p_snapshot is null or jsonb_typeof(p_snapshot) <> 'object' or
     p_snapshot->>'schemaVersion' <> '4' or p_snapshot ? 'changeHistory' or
     jsonb_typeof(p_snapshot->'preferences') is distinct from 'object' or
     octet_length(p_snapshot::text) > 4000000 then
    raise exception 'Invalid or oversized snapshot';
  end if;
  foreach k in array array['accounts','categories','transactions','budgets','goals','recurring','rules'] loop
    if jsonb_typeof(p_snapshot->k) is distinct from 'array' then raise exception 'Invalid snapshot array'; end if;
  end loop;
end $$;

create function public.mora_envelope(p_household_id uuid) returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object('household_id', id, 'name', name, 'version', version, 'snapshot', snapshot)
  from public.mora_households where id = p_household_id
$$;

create function public.mora_create_household(p_name text, p_snapshot jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare h uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if (select count(*) from public.mora_households where owner_id = auth.uid()) >= 5 then
    raise exception 'Household limit reached';
  end if;
  perform public.mora_validate_snapshot(p_snapshot);
  insert into public.mora_households(owner_id, name, snapshot) values(auth.uid(), trim(p_name), p_snapshot) returning id into h;
  insert into public.mora_members values(h, auth.uid());
  return public.mora_envelope(h);
end $$;

create function public.mora_list_households() returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name) order by h.name), '[]'::jsonb)
  from public.mora_households h join public.mora_members m on m.household_id = h.id where m.user_id = auth.uid()
$$;

create function public.mora_get_household(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return public.mora_envelope(p_household_id);
end $$;

create function public.mora_save_household(p_household_id uuid, p_version bigint, p_snapshot jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
declare changed integer;
begin
  perform public.mora_require_member(p_household_id);
  perform public.mora_validate_snapshot(p_snapshot);
  update public.mora_households set snapshot = p_snapshot, version = version + 1, updated_at = now()
    where id = p_household_id and version = p_version;
  get diagnostics changed = row_count;
  return changed = 1;
end $$;

-- Poll a tiny revision marker instead of downloading the entire ledger every time.
create function public.mora_get_status(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select jsonb_build_object('version', h.version, 'pending_count',
    (select count(*) from public.mora_captures where household_id = h.id and state = 'pending'))
    from public.mora_households h where h.id = p_household_id);
end $$;

create function public.mora_create_invitation(p_household_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare secret text;
begin
  perform public.mora_require_member(p_household_id);
  if not exists(select 1 from public.mora_households where id = p_household_id and owner_id = auth.uid()) then
    raise exception 'Only the owner can invite members' using errcode = '42501';
  end if;
  secret := encode(extensions.gen_random_bytes(32), 'hex');
  delete from public.mora_invitations where household_id = p_household_id;
  insert into public.mora_invitations(token_hash, household_id) values(extensions.digest(secret, 'sha256'), p_household_id);
  return secret;
end $$;

create function public.mora_join_household(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare h uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  delete from public.mora_invitations where token_hash = extensions.digest(trim(p_code), 'sha256') and expires_at > now()
    returning household_id into h;
  if h is null then raise exception 'Invitation invalid, expired or already used'; end if;
  insert into public.mora_members values(h, auth.uid()) on conflict do nothing;
  return public.mora_envelope(h);
end $$;

create function public.mora_create_phone_token(p_household_id uuid, p_account_id uuid, p_label text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare secret text; token_id uuid;
begin
  perform public.mora_require_member(p_household_id);
  if not exists(select 1 from public.mora_households h, jsonb_array_elements(h.snapshot->'accounts') a
    where h.id = p_household_id and (a->>'id')::uuid = p_account_id and not coalesce((a->>'archived')::boolean,false)) then
    raise exception 'Select an active shared account';
  end if;
  if (select count(*) from public.mora_phone_tokens where household_id = p_household_id and user_id = auth.uid() and revoked_at is null) >= 20 then
    raise exception 'Revoke an old phone token first';
  end if;
  secret := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.mora_phone_tokens(token_hash, household_id, user_id, account_id, label)
    values(extensions.digest(secret,'sha256'), p_household_id, auth.uid(), p_account_id, trim(p_label)) returning id into token_id;
  return jsonb_build_object('id', token_id, 'token', secret);
end $$;

create function public.mora_list_phone_tokens(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'label',label,'account_id',account_id,'revoked',revoked_at is not null) order by created_at),'[]'::jsonb)
    from public.mora_phone_tokens where household_id = p_household_id and user_id = auth.uid());
end $$;

create function public.mora_revoke_phone_token(p_token_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare changed integer;
begin
  update public.mora_phone_tokens set revoked_at = now() where id = p_token_id and user_id = auth.uid();
  get diagnostics changed = row_count;
  return changed = 1;
end $$;

-- Internal helper. Its caller has already locked the household. Never exposed to clients.
create function public.mora_append_payment(p_household_id uuid, p_capture_id uuid, p_account_id uuid,
  p_amount numeric, p_currency text, p_merchant text, p_date timestamptz, p_label text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare snap jsonb; account jsonb; cat jsonb; tx jsonb; txid uuid := gen_random_uuid();
begin
  select snapshot into snap from public.mora_households where id = p_household_id;
  select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid = p_account_id;
  if account is null or coalesce((account->>'archived')::boolean,false) or account->>'currency' <> p_currency then
    raise exception 'Account missing, archived or currency differs';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 999999999999 or length(trim(p_merchant)) = 0 then
    raise exception 'Invalid payment';
  end if;
  select c into cat from jsonb_array_elements(snap->'rules') with ordinality r(rule, ord),
    jsonb_array_elements(snap->'categories') c
    where position(lower(r.rule->>'keyword') in lower(p_merchant)) > 0 and length(trim(r.rule->>'keyword')) > 0
    and c->>'id' = r.rule->>'categoryID' and c->>'kind' = 'expense' order by r.ord limit 1;
  tx := jsonb_build_object('id', upper(txid::text), 'date', to_char(p_date at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'merchant', trim(p_merchant), 'amount', -p_amount, 'accountID', upper(p_account_id::text), 'kind', 'expense',
    'note', 'Apple Pay · ' || p_label || ' · сумма предварительная', 'tags', jsonb_build_array('Apple Pay','Предварительно'),
    'externalID', 'wallet:' || p_capture_id::text);
  if cat is not null then tx := tx || jsonb_build_object('categoryID',cat->>'id'); end if;
  snap := jsonb_set(snap, '{transactions}', (snap->'transactions') || jsonb_build_array(tx));
  perform public.mora_validate_snapshot(snap);
  update public.mora_households set snapshot = snap, version = version + 1, updated_at = now() where id = p_household_id;
  return txid;
end $$;

-- Public HTTPS ingress: a publishable project key + a random write-only phone token.
-- Missing information is kept in the inbox; it never becomes a guessed expense.
create function public.mora_capture_payment(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.mora_phone_tokens; capture public.mora_captures; snap jsonb; account jsonb;
  amount numeric; reason text; label text;
begin
  if p_token is null or length(p_token) <> 64 then raise exception 'Invalid phone token' using errcode = '42501'; end if;
  select * into t from public.mora_phone_tokens where token_hash = extensions.digest(p_token,'sha256') and revoked_at is null;
  if t.id is null or not exists(select 1 from public.mora_members where household_id=t.household_id and user_id=t.user_id) then
    raise exception 'Invalid phone token' using errcode = '42501';
  end if;
  -- Same lock as desktop compare-and-swap; concurrent phone/desktop writes are serialized.
  select snapshot into snap from public.mora_households where id=t.household_id for update;
  select * into capture from public.mora_captures where phone_token_id=t.id and event_id=p_event_id;
  if capture.id is not null then return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',true); end if;
  if p_event_id is null or p_occurred_at is null or not isfinite(p_occurred_at) or
    length(coalesce(p_amount,'')) > 64 or length(coalesce(p_merchant,'')) > 300 or length(coalesce(p_currency,'')) > 10 then
    raise exception 'Invalid payment input';
  end if;
  if (select count(*) from public.mora_captures where phone_token_id=t.id and created_at > now()-interval '1 day') >= 500 then
    raise exception 'Phone daily limit reached' using errcode = '54000';
  end if;
  p_amount := trim(coalesce(p_amount,'')); p_currency := upper(trim(coalesce(p_currency,''))); p_merchant := trim(coalesce(p_merchant,''));
  if p_amount ~ '^[0-9]{1,12}([.,][0-9]{1,6})?$' then amount := replace(p_amount,',','.')::numeric; end if;
  select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=t.account_id;
  reason := case when amount is null or amount <= 0 then 'Не получена положительная сумма'
    when p_merchant = '' then 'Не получено название продавца'
    when p_currency = '' then 'Не получена валюта покупки'
    when account is null or coalesce((account->>'archived')::boolean,false) then 'Счет недоступен'
    when account->>'currency' <> p_currency then 'Валюта покупки отличается от валюты счета' else null end;
  insert into public.mora_captures(household_id,phone_token_id,event_id,account_id,merchant,amount_text,currency,occurred_at,state,reason)
    values(t.household_id,t.id,p_event_id,t.account_id,p_merchant,p_amount,p_currency,p_occurred_at,'pending',reason) returning * into capture;
  if reason is null then
    capture.transaction_id := public.mora_append_payment(t.household_id,capture.id,t.account_id,amount,p_currency,p_merchant,p_occurred_at,t.label);
    update public.mora_captures set state='recorded',transaction_id=capture.transaction_id where id=capture.id;
    capture.state := 'recorded';
  end if;
  return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',false,'reason',reason);
end $$;

create function public.mora_list_pending(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'merchant',c.merchant,'amount',c.amount_text,'currency',c.currency,
    'account_id',c.account_id,'date',to_char(c.occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'reason',c.reason,'label',t.label) order by c.created_at desc),'[]'::jsonb)
    from public.mora_captures c join public.mora_phone_tokens t on t.id=c.phone_token_id where c.household_id=p_household_id and c.state='pending');
end $$;

create function public.mora_resolve_capture(p_household_id uuid, p_capture_id uuid, p_account_id uuid,
  p_amount text, p_merchant text, p_dismiss boolean default false) returns boolean
language plpgsql security definer set search_path = '' as $$
declare c public.mora_captures; currency text; label text; txid uuid; amount numeric;
begin
  perform public.mora_require_member(p_household_id);
  perform 1 from public.mora_households where id=p_household_id for update;
  select * into c from public.mora_captures where id=p_capture_id and household_id=p_household_id for update;
  if c.id is null then raise exception 'Capture missing'; end if;
  if c.state <> 'pending' then return false; end if;
  if p_dismiss then update public.mora_captures set state='dismissed' where id=c.id; return true; end if;
  if trim(p_amount) !~ '^[0-9]{1,12}([.,][0-9]{1,6})?$' then raise exception 'Invalid amount'; end if;
  amount := replace(trim(p_amount),',','.')::numeric;
  select a->>'currency' into currency from public.mora_households h, jsonb_array_elements(h.snapshot->'accounts') a
    where h.id=p_household_id and (a->>'id')::uuid=p_account_id;
  select t.label into label from public.mora_phone_tokens t where t.id=c.phone_token_id;
  txid := public.mora_append_payment(p_household_id,c.id,p_account_id,amount,currency,p_merchant,c.occurred_at,label);
  update public.mora_captures set state='recorded',transaction_id=txid,reason=null where id=c.id;
  return true;
end $$;

-- PostgreSQL grants function execution to PUBLIC by default. Revoke for every
-- Mora function, including internal helpers, then grant only the public surface.
do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'mora_%' loop
    execute format('revoke all on function %s from public, anon, authenticated',f.signature);
  end loop;
end $$;
grant execute on function public.mora_create_household(text,jsonb), public.mora_list_households(),
  public.mora_get_household(uuid), public.mora_get_status(uuid), public.mora_save_household(uuid,bigint,jsonb),
  public.mora_create_invitation(uuid), public.mora_join_household(text),
  public.mora_create_phone_token(uuid,uuid,text), public.mora_list_phone_tokens(uuid),
  public.mora_revoke_phone_token(uuid), public.mora_list_pending(uuid),
  public.mora_resolve_capture(uuid,uuid,uuid,text,text,boolean) to authenticated;
grant execute on function public.mora_capture_payment(text,uuid,text,text,text,timestamptz) to anon, authenticated;
commit;
