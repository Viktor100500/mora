-- Telegram bot (functions/mora-telegram): purchases from a strict form in a
-- Telegram Mini App or widget. The function holds one phone key in its secrets
-- and never shows it to Telegram. Unlike the Apple Pay shortcut, the form names
-- the account and the category. A purchase in the account's currency is booked
-- at once; another currency waits in the inbox, where open Mora converts it at
-- the Visa rate as for Apple Pay. Booked purchases use the Wallet convention
-- (transaction id = capture id, externalID wallet:<id>), so Mora collects them
-- into a rollbackable import. Apply after wallet_card_currency_accounts.
begin;

-- Internal: the active phone key. The member who created it must still belong to the household.
create function public.mora_phone_token_check(p_token text) returns public.mora_phone_tokens
language plpgsql security definer set search_path = '' as $$
declare t public.mora_phone_tokens;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'Invalid phone token' using errcode = '42501'; end if;
  select * into t from public.mora_phone_tokens where token_hash = extensions.digest(p_token,'sha256') and revoked_at is null;
  if t.id is null or not exists(select 1 from public.mora_members where household_id=t.household_id and user_id=t.user_id) then
    raise exception 'Invalid phone token' using errcode = '42501';
  end if;
  return t;
end $$;

-- What the form offers: active accounts, expense categories, this key's recent
-- merchants with the category they were last booked with, and this key's totals.
create function public.mora_phone_context(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.mora_phone_tokens := public.mora_phone_token_check(p_token); snap jsonb;
begin
  select snapshot into snap from public.mora_households where id=t.household_id;
  return jsonb_build_object(
    'label', t.label,
    'base_currency', snap#>>'{preferences,baseCurrency}',
    'default_account_id', lower(t.account_id::text),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', lower(a->>'id'), 'name', a->>'name', 'currency', a->>'currency') order by n)
      from jsonb_array_elements(snap->'accounts') with ordinality rows(a, n)
      where not coalesce((a->>'archived')::boolean,false)), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', lower(c->>'id'), 'name', c->>'name') order by n)
      from jsonb_array_elements(snap->'categories') with ordinality rows(c, n) where c->>'kind'='expense'), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('merchant', r.merchant, 'account_id', lower(r.account_id::text),
        'currency', r.currency, 'category_id', lower(r.category_id)) order by r.last desc)
      from (select distinct on (lower(c.merchant)) c.merchant, c.account_id, c.currency, c.created_at last,
          (select t2->>'categoryID' from jsonb_array_elements(snap->'transactions') t2
            where lower(t2->>'id') = c.transaction_id::text limit 1) category_id
        from public.mora_captures c
        where c.phone_token_id=t.id and c.state<>'dismissed' and length(btrim(c.merchant))>0
          and c.created_at > now() - interval '90 days'
        order by lower(c.merchant), c.created_at desc) r
      ), '[]'::jsonb),
    -- Totals per purchase currency, in UTC days and months.
    'totals', jsonb_build_object(
      'today', coalesce((select jsonb_object_agg(currency, total) from (select c.currency, sum(public.mora_parse_payment_amount(c.amount_text)) total
        from public.mora_captures c where c.phone_token_id=t.id and c.state<>'dismissed' and c.currency<>''
          and c.occurred_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC'
        group by c.currency having sum(public.mora_parse_payment_amount(c.amount_text)) is not null) x), '{}'::jsonb),
      'month', coalesce((select jsonb_object_agg(currency, total) from (select c.currency, sum(public.mora_parse_payment_amount(c.amount_text)) total
        from public.mora_captures c where c.phone_token_id=t.id and c.state<>'dismissed' and c.currency<>''
          and c.occurred_at >= date_trunc('month', now() at time zone 'UTC') at time zone 'UTC'
        group by c.currency having sum(public.mora_parse_payment_amount(c.amount_text)) is not null) x), '{}'::jsonb)));
end $$;

-- One purchase from the form. The same event id never records twice.
create function public.mora_phone_add_purchase(p_token text, p_event_id uuid, p_account_id uuid, p_amount numeric,
  p_currency text, p_merchant text, p_category_id uuid, p_note text, p_occurred_at timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.mora_phone_tokens := public.mora_phone_token_check(p_token); capture public.mora_captures;
  snap jsonb; account jsonb; category jsonb; reason text; tx jsonb; amount_text text;
begin
  select snapshot into snap from public.mora_households where id=t.household_id for update;
  select * into capture from public.mora_captures where phone_token_id=t.id and event_id=p_event_id;
  if capture.id is not null then return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',true,'reason',capture.reason); end if;
  p_currency := upper(btrim(coalesce(p_currency,'')));
  p_merchant := btrim(regexp_replace(coalesce(p_merchant,''), '\s+', ' ', 'g'));
  p_note := btrim(coalesce(p_note,''));
  if p_event_id is null or p_occurred_at is null or not isfinite(p_occurred_at)
    or p_occurred_at > now() + interval '1 day' or p_occurred_at < now() - interval '366 days' then
    raise exception 'Invalid purchase date';
  end if;
  if p_currency !~ '^[A-Z]{3}$' then raise exception 'Invalid purchase currency'; end if;
  if length(p_merchant) not between 1 and 300 then raise exception 'Enter the merchant'; end if;
  if length(p_note) > 500 then raise exception 'Note is too long'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 999999999999
    or round(p_amount, public.mora_currency_decimals(p_currency)) <> p_amount then
    raise exception 'Amount must be positive with at most % decimals for %', public.mora_currency_decimals(p_currency), p_currency;
  end if;
  select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=p_account_id;
  if account is null or coalesce((account->>'archived')::boolean,false) then raise exception 'Select an active shared account'; end if;
  if p_category_id is not null then
    select c into category from jsonb_array_elements(snap->'categories') c where (c->>'id')::uuid=p_category_id and c->>'kind'='expense';
    if category is null then raise exception 'Select an expense category'; end if;
  end if;
  if (select count(*) from public.mora_captures where phone_token_id=t.id and created_at > now()-interval '1 day') >= 500 then
    raise exception 'Phone daily limit reached' using errcode = '54000';
  end if;
  amount_text := p_amount::text;
  reason := public.mora_capture_reason(amount_text, p_currency, p_merchant, account, false);
  insert into public.mora_captures(household_id,phone_token_id,event_id,account_id,merchant,amount_text,currency,occurred_at,state,reason)
    values(t.household_id,t.id,p_event_id,p_account_id,p_merchant,amount_text,p_currency,p_occurred_at,'pending',reason) returning * into capture;
  if reason is null then
    if category is null then
      -- Same keyword rules as Mora itself.
      select c into category from jsonb_array_elements(snap->'rules') with ordinality r(rule, ord),
        jsonb_array_elements(snap->'categories') c
        where length(btrim(r.rule->>'keyword')) > 0 and position(lower(r.rule->>'keyword') in lower(p_merchant)) > 0
          and c->>'id' = r.rule->>'categoryID' and c->>'kind' = 'expense' order by r.ord limit 1;
    end if;
    tx := jsonb_build_object('id', upper(capture.id::text), 'date', to_char(p_occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'merchant', p_merchant, 'amount', -p_amount, 'accountID', upper(p_account_id::text), 'kind', 'expense',
      'note', concat_ws(' · ', nullif(p_note,''), t.label), 'tags', jsonb_build_array('Telegram'),
      'externalID', 'wallet:' || capture.id::text);
    if category is not null then tx := tx || jsonb_build_object('categoryID', category->>'id'); end if;
    snap := jsonb_set(snap, '{transactions}', (snap->'transactions') || jsonb_build_array(tx));
    perform public.mora_validate_snapshot(snap);
    update public.mora_households set snapshot=snap, version=version+1, updated_at=now() where id=t.household_id;
    update public.mora_captures set state='recorded', transaction_id=capture.id where id=capture.id;
    capture.state := 'recorded';
  end if;
  return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',false,'reason',reason,
    'account',account->>'name','category',category->>'name');
end $$;

revoke all on function public.mora_phone_token_check(text), public.mora_phone_context(text),
  public.mora_phone_add_purchase(text,uuid,uuid,numeric,text,text,uuid,text,timestamptz) from public, anon, authenticated;
-- The Telegram function calls these with the publishable key; the phone key is the credential.
grant execute on function public.mora_phone_context(text),
  public.mora_phone_add_purchase(text,uuid,uuid,numeric,text,text,uuid,text,timestamptz) to anon, authenticated;
commit;
notify pgrst, 'reload schema';
