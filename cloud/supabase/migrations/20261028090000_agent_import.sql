-- AI agents record transactions into the shared database through the remote MCP
-- function (functions/mora-mcp). Each connection has its own random key that can
-- only read account and category names with recent transactions, and add new
-- transactions as one import batch that Mora can roll back. Apply after wallet_cards.
begin;
create table public.mora_agent_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash bytea not null unique,
  household_id uuid not null references public.mora_households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null check (length(label) between 1 and 100),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
create index mora_agent_tokens_household on public.mora_agent_tokens(household_id);
alter table public.mora_agent_tokens enable row level security;
revoke all on public.mora_agent_tokens from anon, authenticated;

create function public.mora_create_agent_token(p_household_id uuid, p_label text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare token text := encode(extensions.gen_random_bytes(32), 'hex'); new_id uuid;
begin
  perform public.mora_require_member(p_household_id);
  if length(trim(coalesce(p_label, ''))) not between 1 and 100 then raise exception 'Invalid label'; end if;
  if (select count(*) from public.mora_agent_tokens where household_id = p_household_id and revoked_at is null) >= 10 then
    raise exception 'Agent connection limit reached';
  end if;
  insert into public.mora_agent_tokens(token_hash, household_id, user_id, label)
    values(extensions.digest(token, 'sha256'), p_household_id, auth.uid(), trim(p_label)) returning mora_agent_tokens.id into new_id;
  return jsonb_build_object('id', new_id, 'token', token);
end $$;

create function public.mora_list_agent_tokens(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  -- Whole-second UTC times decode with the apps' ISO 8601 decoders.
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', label,
      'created_at', to_char(created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'last_used_at', to_char(last_used_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) order by created_at desc)
    from public.mora_agent_tokens where household_id = p_household_id and revoked_at is null), '[]'::jsonb);
end $$;

-- Any member may disconnect an agent of the shared database.
create function public.mora_revoke_agent_token(p_token_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare h uuid; changed integer;
begin
  select household_id into h from public.mora_agent_tokens where id = p_token_id;
  if h is null then return false; end if;
  perform public.mora_require_member(h);
  update public.mora_agent_tokens set revoked_at = now() where id = p_token_id and revoked_at is null;
  get diagnostics changed = row_count;
  return changed = 1;
end $$;

-- Internal: the active key's household. The member who created it must still belong to it.
create function public.mora_agent_household(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare t public.mora_agent_tokens;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'Invalid agent key' using errcode = '42501'; end if;
  select * into t from public.mora_agent_tokens where token_hash = extensions.digest(p_token, 'sha256') and revoked_at is null;
  if t.id is null or not exists(select 1 from public.mora_members where household_id = t.household_id and user_id = t.user_id) then
    raise exception 'Agent key revoked or unknown' using errcode = '42501';
  end if;
  update public.mora_agent_tokens set last_used_at = now() where id = t.id;
  return t.household_id;
end $$;

create function public.mora_currency_decimals(p_currency text) returns integer
language sql immutable set search_path = '' as $$
  select case when p_currency = any(array['BIF','CLP','DJF','GNF','ISK','JPY','KMF','KRW','PYG','RWF','UGX','UYI','VND','VUV','XAF','XOF','XPF']) then 0
    when p_currency = any(array['BHD','IQD','JOD','KWD','LYD','OMR','TND']) then 3
    when p_currency = any(array['CLF','UYW']) then 4 else 2 end
$$;

create function public.mora_agent_context(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare h uuid := public.mora_agent_household(p_token); snap jsonb; household_name text;
begin
  select snapshot, mora_households.name into snap, household_name from public.mora_households where id = h;
  return jsonb_build_object(
    'household', household_name,
    'base_currency', snap#>>'{preferences,baseCurrency}',
    'today_utc', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a->>'id', 'name', a->>'name',
        'currency', a->>'currency', 'kind', a->>'kind') order by n)
      from jsonb_array_elements(snap->'accounts') with ordinality rows(a, n)
      where not coalesce((a->>'archived')::boolean, false)), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c->>'id', 'name', c->>'name', 'kind', c->>'kind') order by n)
      from jsonb_array_elements(snap->'categories') with ordinality rows(c, n)), '[]'::jsonb),
    -- Recent history lets the agent skip rows that are already recorded.
    'recent_transactions', coalesce((select jsonb_agg(r order by r->>'date' desc) from (
      select jsonb_build_object('date', left(t->>'date', 10), 'description', t->>'merchant', 'amount', (t->>'amount')::numeric,
        'kind', t->>'kind', 'account', (select a->>'name' from jsonb_array_elements(snap->'accounts') a where a->>'id' = t->>'accountID')) r
      from jsonb_array_elements(snap->'transactions') t
      where (t->>'date')::timestamptz >= now() - interval '60 days'
      order by t->>'date' desc limit 300) recent), '[]'::jsonb));
end $$;

-- Validates every row first: either all new rows are recorded as one import or
-- none are, with the reasons listed so the agent can correct them.
create function public.mora_agent_add_transactions(p_token text, p_transactions jsonb, p_source text default null,
  p_skip_duplicates boolean default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare h uuid := public.mora_agent_household(p_token); snap jsonb; imports jsonb; item jsonb; tx jsonb;
  account jsonb; destination jsonb; category jsonb; errors text[] := '{}'; added jsonb := '[]'::jsonb;
  skipped jsonb := '[]'::jsonb; n_row integer := 0; kind text; amount numeric; credited numeric;
  occurred timestamptz; day text; external text; batch_id uuid := gen_random_uuid(); batch_label text;
  stamp text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'); tags jsonb; existing jsonb;
begin
  if jsonb_typeof(p_transactions) is distinct from 'array' or jsonb_array_length(p_transactions) not between 1 and 500
    or octet_length(p_transactions::text) > 1000000 then
    raise exception 'Pass 1 to 500 transactions';
  end if;
  select snapshot into snap from public.mora_households where id = h for update;
  imports := case when jsonb_typeof(snap->'imports') = 'array' then snap->'imports' else '[]'::jsonb end;
  existing := snap->'transactions';
  for item in select value from jsonb_array_elements(p_transactions) loop
    n_row := n_row + 1;
    begin
      if jsonb_typeof(item) is distinct from 'object' then raise exception 'not an object'; end if;
      kind := coalesce(item->>'kind', 'expense');
      if kind not in ('expense', 'income', 'transfer') then raise exception 'kind must be expense, income or transfer'; end if;
      if jsonb_typeof(item->'amount') is distinct from 'number' then raise exception 'amount must be a number'; end if;
      amount := abs((item->>'amount')::numeric);
      if length(trim(coalesce(item->>'description', ''))) not between 1 and 2000 then raise exception 'description is required'; end if;
      if coalesce(item->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$' then
        -- A calendar day keeps its date in every time zone between UTC-11 and UTC+11.
        occurred := ((item->>'date') || 'T12:00:00Z')::timestamptz;
      else
        occurred := (item->>'date')::timestamptz;
      end if;
      if occurred is null or not isfinite(occurred) or occurred > now() + interval '366 days' or occurred < '1970-01-01'::timestamptz then
        raise exception 'date must be YYYY-MM-DD or an ISO 8601 time';
      end if;
      day := to_char(occurred at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
      select a into account from jsonb_array_elements(snap->'accounts') a
        where not coalesce((a->>'archived')::boolean, false)
          and (lower(a->>'id') = lower(item->>'account') or lower(trim(a->>'name')) = lower(trim(item->>'account')))
        limit 1;
      if account is null then raise exception 'account "%" not found; use a name or id from get_mora_context', item->>'account'; end if;
      if amount = 0 or amount > 999999999999 or round(amount, public.mora_currency_decimals(account->>'currency')) <> amount then
        raise exception 'amount must be positive with at most % decimals for %', public.mora_currency_decimals(account->>'currency'), account->>'currency';
      end if;
      tags := coalesce(item->'tags', '[]'::jsonb);
      if jsonb_typeof(tags) <> 'array' or jsonb_array_length(tags) > 20 or exists(select 1 from jsonb_array_elements(tags) tag
        where jsonb_typeof(tag) <> 'string' or length(tag#>>'{}') not between 1 and 100) then raise exception 'tags must be up to 20 short strings'; end if;
      if length(coalesce(item->>'note', '')) > 2000 then raise exception 'note is too long'; end if;
      tx := jsonb_build_object('id', upper(gen_random_uuid()::text), 'date', day, 'merchant', trim(item->>'description'),
        'amount', case when kind = 'income' then amount else -amount end, 'accountID', upper(account->>'id'), 'kind', kind,
        'note', coalesce(item->>'note', ''), 'tags', tags, 'importBatchID', upper(batch_id::text));
      if kind = 'transfer' then
        if item ? 'category' and item->>'category' is not null then raise exception 'transfers have no category'; end if;
        select a into destination from jsonb_array_elements(snap->'accounts') a
          where not coalesce((a->>'archived')::boolean, false)
            and (lower(a->>'id') = lower(item->>'to_account') or lower(trim(a->>'name')) = lower(trim(item->>'to_account')))
          limit 1;
        if destination is null or destination->>'id' = account->>'id' then raise exception 'to_account must be another existing account'; end if;
        if destination->>'currency' = account->>'currency' then
          credited := amount;
        elsif jsonb_typeof(item->'to_amount') = 'number' and (item->>'to_amount')::numeric > 0 then
          credited := (item->>'to_amount')::numeric;
        else
          raise exception 'to_amount in % is required between different currencies', destination->>'currency';
        end if;
        tx := tx || jsonb_build_object('destinationAccountID', upper(destination->>'id'), 'destinationAmount', credited);
      else
        category := null;
        if nullif(trim(coalesce(item->>'category', '')), '') is not null then
          select c into category from jsonb_array_elements(snap->'categories') c
            where c->>'kind' = kind and (lower(c->>'id') = lower(item->>'category') or lower(trim(c->>'name')) = lower(trim(item->>'category')))
            limit 1;
          if category is null then raise exception 'category "%" not found for %', item->>'category', kind; end if;
        else
          -- Same keyword rules as Mora itself.
          select c into category from jsonb_array_elements(snap->'rules') with ordinality r(rule, ord),
            jsonb_array_elements(snap->'categories') c
            where length(trim(r.rule->>'keyword')) > 0 and position(lower(r.rule->>'keyword') in lower(item->>'description')) > 0
              and c->>'id' = r.rule->>'categoryID' and c->>'kind' = kind order by r.ord limit 1;
        end if;
        if category is not null then tx := tx || jsonb_build_object('categoryID', category->>'id'); end if;
      end if;
      external := nullif(trim(coalesce(item->>'external_id', '')), '');
      if external is not null then
        if length(external) > 200 then raise exception 'external_id is too long'; end if;
        tx := tx || jsonb_build_object('externalID', 'agent:' || external);
      end if;
      if (external is not null and exists(select 1 from jsonb_array_elements(snap->'transactions') t where t->>'externalID' = 'agent:' || external))
        -- Identical rows within one request are separate purchases; only recorded ones count as duplicates.
        or (p_skip_duplicates and exists(select 1 from jsonb_array_elements(existing) t
          where t->>'accountID' = tx->>'accountID' and left(t->>'date', 10) = left(day, 10)
            and (t->>'amount')::numeric = (tx->>'amount')::numeric and lower(trim(t->>'merchant')) = lower(tx->>'merchant'))) then
        skipped := skipped || jsonb_build_array(jsonb_build_object('row', n_row, 'description', tx->>'merchant'));
      else
        snap := jsonb_set(snap, '{transactions}', (snap->'transactions') || jsonb_build_array(tx));
        added := added || jsonb_build_array(tx);
      end if;
    exception when others then
      errors := errors || format('row %s: %s', n_row, sqlerrm);
    end;
  end loop;
  if cardinality(errors) > 0 then
    raise exception 'Nothing was recorded. Fix these rows and send all of them again: %', left(array_to_string(errors, '; '), 3000);
  end if;
  if jsonb_array_length(added) > 0 then
    batch_label := coalesce(nullif(left(trim(p_source), 100), ''), 'AI-агент');
    imports := imports || jsonb_build_array(jsonb_build_object('id', upper(batch_id::text), 'filename', batch_label,
      'source', 'AI agent', 'createdAt', stamp, 'totalRows', jsonb_array_length(p_transactions), 'excluded', 0,
      'duplicates', jsonb_array_length(skipped), 'invalid', 0, 'transactions', added,
      'accountNames', coalesce((select jsonb_object_agg(upper(a->>'id'), a->>'name') from jsonb_array_elements(snap->'accounts') a), '{}'::jsonb),
      'currencies', coalesce((select jsonb_object_agg(upper(a->>'id'), a->>'currency') from jsonb_array_elements(snap->'accounts') a), '{}'::jsonb),
      'categoryNames', coalesce((select jsonb_object_agg(upper(c->>'id'), c->>'name') from jsonb_array_elements(snap->'categories') c), '{}'::jsonb)));
    snap := jsonb_set(snap, '{imports}', imports);
    perform public.mora_validate_snapshot(snap);
    update public.mora_households set snapshot = snap, version = version + 1, updated_at = now() where id = h;
  end if;
  return jsonb_build_object('added', jsonb_array_length(added), 'skipped_duplicates', skipped,
    'import_id', case when jsonb_array_length(added) > 0 then batch_id end,
    'transactions', coalesce((select jsonb_agg(jsonb_build_object('date', left(t->>'date', 10), 'description', t->>'merchant',
      'amount', (t->>'amount')::numeric, 'kind', t->>'kind',
      'category', (select c->>'name' from jsonb_array_elements(snap->'categories') c where c->>'id' = t->>'categoryID'))) from jsonb_array_elements(added) t), '[]'::jsonb));
end $$;

revoke all on function public.mora_create_agent_token(uuid,text), public.mora_list_agent_tokens(uuid),
  public.mora_revoke_agent_token(uuid), public.mora_agent_household(text), public.mora_currency_decimals(text),
  public.mora_agent_context(text), public.mora_agent_add_transactions(text,jsonb,text,boolean) from public, anon, authenticated;
grant execute on function public.mora_create_agent_token(uuid,text), public.mora_list_agent_tokens(uuid),
  public.mora_revoke_agent_token(uuid) to authenticated;
-- The MCP function calls these with the publishable key; the agent key is the credential.
grant execute on function public.mora_agent_context(text), public.mora_agent_add_transactions(text,jsonb,text,boolean) to anon, authenticated;
commit;
notify pgrst, 'reload schema';
