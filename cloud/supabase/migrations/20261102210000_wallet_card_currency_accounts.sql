-- A multi-currency card is linked to several accounts. A purchase goes to the
-- card account in the purchase currency; any other currency goes to the card's
-- main account (mora_wallet_cards.account_id) and is converted as before.
-- Wallet amounts in any ISO currency, e.g. "RSD 1,234.00", are now recognized.
begin;
create table public.mora_wallet_card_accounts (
  card_id uuid not null references public.mora_wallet_cards(id) on delete cascade,
  account_id uuid not null,
  primary key (card_id, account_id)
);
alter table public.mora_wallet_card_accounts enable row level security;
revoke all on public.mora_wallet_card_accounts from anon, authenticated;

create or replace function public.mora_parse_payment_currency(p_input text) returns text
language plpgsql immutable set search_path = '' as $$
declare value text; code text;
  whitespace text := E' \t\n\r' || chr(160) || chr(8239);
begin
  if p_input is null or length(p_input) > 64 then return null; end if;
  value := upper(btrim(p_input, whitespace));
  code := substring(value from '^([A-Z]{3})(?:[^A-Z]|$)');
  if code is null then code := substring(value from '(?:^|[^A-Z])([A-Z]{3})$'); end if;
  if code is not null then return code; end if;
  if left(value,1)='$' or right(value,1)='$' then return 'USD'; end if;
  if left(value,1)='€' or right(value,1)='€' then return 'EUR'; end if;
  if left(value,1)='₽' or right(value,1)='₽' then return 'RUB'; end if;
  return null;
end $$;
revoke all on function public.mora_parse_payment_currency(text) from public, anon, authenticated;

create or replace function public.mora_parse_payment_amount(p_input text) returns numeric
language plpgsql immutable set search_path = '' as $$
declare value text; stripped text; amount numeric;
  whitespace text := E' \t\n\r' || chr(160) || chr(8239);
begin
  if p_input is null or length(p_input) > 64 then return null; end if;
  value := btrim(p_input, whitespace);
  stripped := regexp_replace(value, '^([$€£¥₽]|[A-Z]{3})', '', 'i');
  if stripped <> value then
    value := btrim(stripped, whitespace);
  else
    value := btrim(regexp_replace(value, '([$€£¥₽]|[A-Z]{3})$', '', 'i'), whitespace);
  end if;
  -- Group separators are accepted only when every group contains three digits.
  if value ~ '^[0-9]{1,3}(,[0-9]{3})+\.[0-9]{1,6}$' then
    value := replace(value, ',', '');
  elsif value ~ '^[0-9]{1,3}(\.[0-9]{3})+,[0-9]{1,6}$' then
    value := replace(value, '.', '');
  elsif value ~ ('^[0-9]{1,3}([' || whitespace || '][0-9]{3})+([.,][0-9]{1,6})?$') then
    value := regexp_replace(value, '[' || whitespace || ']', '', 'g');
  end if;
  if value !~ '^[0-9]{1,12}([.,][0-9]{1,6})?$' then return null; end if;
  amount := replace(value, ',', '.')::numeric;
  if amount <= 0 or amount > 999999999999 then return null; end if;
  return amount;
end $$;
revoke all on function public.mora_parse_payment_amount(text) from public, anon, authenticated;

-- The active card account in the purchase currency, the main account first; otherwise the main account.
create function public.mora_card_account(p_card_id uuid, p_main uuid, p_currency text, p_snapshot jsonb) returns uuid
language sql stable set search_path = '' as $$
  select coalesce((
    select candidate.id from (
      select p_main as id, 0 as priority
      union all select l.account_id, 1 from public.mora_wallet_card_accounts l where l.card_id = p_card_id
    ) candidate
    join lateral jsonb_array_elements(p_snapshot->'accounts') a on (a->>'id')::uuid = candidate.id
    where p_main is not null and a->>'currency' = p_currency and not coalesce((a->>'archived')::boolean,false)
    order by candidate.priority limit 1), p_main)
$$;
revoke all on function public.mora_card_account(uuid,uuid,text,jsonb) from public, anon, authenticated;

create or replace function public.mora_capture_payment(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz, p_card text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.mora_phone_tokens; capture public.mora_captures; snap jsonb; account jsonb;
  amount numeric; reason text; currency_inferred boolean := false;
  v_card text; v_card_id uuid; v_linked uuid; v_target uuid; v_unlinked boolean := false;
begin
  if p_token is null or length(p_token) <> 64 then raise exception 'Invalid phone token' using errcode = '42501'; end if;
  select * into t from public.mora_phone_tokens where token_hash = extensions.digest(p_token,'sha256') and revoked_at is null;
  if t.id is null or not exists(select 1 from public.mora_members where household_id=t.household_id and user_id=t.user_id) then
    raise exception 'Invalid phone token' using errcode = '42501';
  end if;
  select snapshot into snap from public.mora_households where id=t.household_id for update;
  select * into capture from public.mora_captures where phone_token_id=t.id and event_id=p_event_id;
  if capture.id is not null then return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',true); end if;
  if p_event_id is null or p_occurred_at is null or not isfinite(p_occurred_at) or
    length(coalesce(p_amount,'')) > 64 or length(coalesce(p_merchant,'')) > 300 or length(coalesce(p_currency,'')) > 10
    or length(coalesce(p_card,'')) > 400 then
    raise exception 'Invalid payment input';
  end if;
  if (select count(*) from public.mora_captures where phone_token_id=t.id and created_at > now()-interval '1 day') >= 500 then
    raise exception 'Phone daily limit reached' using errcode = '54000';
  end if;
  p_amount := trim(coalesce(p_amount,'')); p_currency := upper(trim(coalesce(p_currency,''))); p_merchant := trim(coalesce(p_merchant,''));
  if p_currency = '' then
    p_currency := coalesce(public.mora_parse_payment_currency(p_amount),'');
    currency_inferred := p_currency <> '';
  end if;
  amount := public.mora_parse_payment_amount(p_amount);

  v_target := t.account_id;
  v_card := public.mora_normalize_card(p_card);
  -- No real default account is offered for an unidentified card. Older clients
  -- also see an unavailable account and cannot automatically book this purchase.
  if t.require_card and v_card is null then v_target := '00000000-0000-0000-0000-000000000000'::uuid; end if;
  if v_card is not null then
    select id, account_id into v_card_id, v_linked from public.mora_wallet_cards
      where phone_token_id=t.id and card_key=lower(v_card);
    if v_card_id is null then
      if (select count(*) from public.mora_wallet_cards where phone_token_id=t.id) >= 50 then
        raise exception 'Too many Wallet cards for this phone key' using errcode = '54000';
      end if;
      insert into public.mora_wallet_cards(household_id, phone_token_id, card_key, card)
        values (t.household_id, t.id, lower(v_card), v_card) returning id into v_card_id;
    else
      update public.mora_wallet_cards set last_seen_at = now() where id = v_card_id;
    end if;
    if v_linked is not null then v_target := public.mora_card_account(v_card_id, v_linked, p_currency, snap);
    else v_unlinked := true; end if;
  end if;

  select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=v_target;
  reason := case when t.require_card and v_card is null then 'Не определена карта оплаты: выберите счёт'
    else public.mora_capture_reason(p_amount, p_currency, p_merchant, account, v_unlinked) end;
  insert into public.mora_captures(household_id,phone_token_id,event_id,account_id,merchant,amount_text,currency,occurred_at,state,reason,card_id)
    values(t.household_id,t.id,p_event_id,v_target,p_merchant,p_amount,p_currency,p_occurred_at,'pending',reason,v_card_id) returning * into capture;
  if reason is null then
    capture.transaction_id := public.mora_append_payment(t.household_id,capture.id,v_target,amount,p_currency,p_merchant,p_occurred_at,concat_ws(' · ',t.label,v_card));
    update public.mora_captures set state='recorded',transaction_id=capture.transaction_id where id=capture.id;
    capture.state := 'recorded';
  end if;
  return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',false,
    'reason',case when currency_inferred and reason='Валюта покупки отличается от валюты счета' then null else reason end,
    'currency',nullif(p_currency,''),'currency_inferred',currency_inferred,
    'card',v_card,'card_linked',v_card is not null and not v_unlinked,
    'next_step',case when v_unlinked then 'mora_link_card'
      when currency_inferred and reason='Валюта покупки отличается от валюты счета' then 'mora_conversion' else null end);
end $$;


-- Link (or unlink with null) a card's main account. Waiting purchases move to the
-- card account for their currency and get a fresh reason.
create or replace function public.mora_link_wallet_card(p_household_id uuid, p_card_id uuid, p_account_id uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare snap jsonb; w public.mora_wallet_cards; account jsonb; c public.mora_captures; target uuid; moved integer := 0;
begin
  perform public.mora_require_member(p_household_id);
  select snapshot into snap from public.mora_households where id=p_household_id for update;
  select * into w from public.mora_wallet_cards where id=p_card_id and household_id=p_household_id for update;
  if w.id is null then raise exception 'Wallet card missing'; end if;
  if p_account_id is not null then
    select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=p_account_id;
    if account is null or coalesce((account->>'archived')::boolean,false) then raise exception 'Select an active shared account'; end if;
  end if;
  update public.mora_wallet_cards set account_id=p_account_id where id=w.id;
  delete from public.mora_wallet_card_accounts where card_id=w.id and account_id=p_account_id;
  for c in select * from public.mora_captures where card_id=w.id and state='pending' for update loop
    target := case when p_account_id is null then (select account_id from public.mora_phone_tokens where id=c.phone_token_id)
      else public.mora_card_account(w.id, p_account_id, c.currency, snap) end;
    select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=target;
    update public.mora_captures set account_id=target,
      reason=public.mora_capture_reason(c.amount_text, c.currency, c.merchant, account, p_account_id is null)
      where id=c.id;
    moved := moved + 1;
  end loop;
  return moved;
end $$;

-- Replace the card's accounts for other currencies: at most one account per currency,
-- none in the main account's currency. Waiting purchases are routed again.
create function public.mora_set_wallet_card_accounts(p_household_id uuid, p_card_id uuid, p_account_ids uuid[]) returns integer
language plpgsql security definer set search_path = '' as $$
declare snap jsonb; w public.mora_wallet_cards; main jsonb; ids uuid[];
begin
  perform public.mora_require_member(p_household_id);
  select snapshot into snap from public.mora_households where id=p_household_id for update;
  select * into w from public.mora_wallet_cards where id=p_card_id and household_id=p_household_id for update;
  if w.id is null then raise exception 'Wallet card missing'; end if;
  if w.account_id is null then raise exception 'Choose the main account of the card first'; end if;
  select a into main from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=w.account_id;
  ids := array(select distinct x from unnest(coalesce(p_account_ids,'{}'::uuid[])) x where x is distinct from w.account_id);
  if cardinality(ids) > 20 then raise exception 'Select at most 20 accounts for a card'; end if;
  if (select count(*) from unnest(ids) x join lateral jsonb_array_elements(snap->'accounts') a on (a->>'id')::uuid=x
      where not coalesce((a->>'archived')::boolean,false)) <> cardinality(ids) then
    raise exception 'Select an active shared account';
  end if;
  if exists(select 1 from unnest(ids) x join lateral jsonb_array_elements(snap->'accounts') a on (a->>'id')::uuid=x
      group by a->>'currency' having count(*)>1 or a->>'currency' = main->>'currency') then
    raise exception 'Select one account per currency for a card';
  end if;
  delete from public.mora_wallet_card_accounts where card_id=w.id;
  insert into public.mora_wallet_card_accounts(card_id, account_id) select w.id, x from unnest(ids) x;
  return public.mora_link_wallet_card(p_household_id, w.id, w.account_id);
end $$;

create or replace function public.mora_list_wallet_cards(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'card',w.card,'account_id',w.account_id,
    'account_ids',(select coalesce(jsonb_agg(l.account_id order by l.account_id),'[]'::jsonb)
      from public.mora_wallet_card_accounts l where l.card_id=w.id),
    'token_id',t.id,'label',t.label,'default_account_id',t.account_id,
    'last_seen',to_char(w.last_seen_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'pending_count',(select count(*) from public.mora_captures c where c.card_id=w.id and c.state='pending'))
    order by t.label, w.card),'[]'::jsonb)
    from public.mora_wallet_cards w join public.mora_phone_tokens t on t.id=w.phone_token_id
    where w.household_id=p_household_id and t.revoked_at is null);
end $$;

revoke all on function public.mora_link_wallet_card(uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.mora_set_wallet_card_accounts(uuid,uuid,uuid[]) from public, anon, authenticated;
revoke all on function public.mora_list_wallet_cards(uuid) from public, anon, authenticated;
revoke all on function public.mora_capture_payment(text,uuid,text,text,text,timestamptz,text) from public, anon, authenticated;
grant execute on function public.mora_capture_payment(text,uuid,text,text,text,timestamptz,text) to anon, authenticated;
grant execute on function public.mora_link_wallet_card(uuid,uuid,uuid), public.mora_set_wallet_card_accounts(uuid,uuid,uuid[]),
  public.mora_list_wallet_cards(uuid) to authenticated;
commit;
notify pgrst, 'reload schema';
