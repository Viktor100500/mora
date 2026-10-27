-- Wallet cards: one phone key per person, the card chooses the account.
-- The Shortcuts sender may pass p_card (the trigger's "Card or Pass" text). Each new card
-- is remembered per phone key and holds its purchases in the inbox until a member links
-- it to an account in Mora. Purchases without p_card keep the key's account, as before.
begin;

create table public.mora_wallet_cards (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.mora_households(id) on delete cascade,
  phone_token_id uuid not null references public.mora_phone_tokens(id) on delete cascade,
  card_key text not null,
  card text not null check (length(card) between 1 and 200),
  account_id uuid,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (phone_token_id, card_key)
);
create index mora_wallet_cards_household on public.mora_wallet_cards(household_id);
alter table public.mora_wallet_cards enable row level security;
revoke all on public.mora_wallet_cards from anon, authenticated;

alter table public.mora_captures add column card_id uuid references public.mora_wallet_cards(id) on delete set null;
create index mora_captures_card on public.mora_captures(card_id);

create function public.mora_normalize_card(p_input text) returns text
language sql immutable set search_path = '' as $$
  select nullif(left(btrim(regexp_replace(coalesce(p_input,''), '[\s' || chr(160) || chr(8239) || ']+', ' ', 'g')), 200), '')
$$;

-- One rule for new and re-routed captures. An unlinked card always waits for the user.
create function public.mora_capture_reason(p_amount text, p_currency text, p_merchant text,
  p_account jsonb, p_card_unlinked boolean) returns text
language sql immutable set search_path = '' as $$
  select case when p_card_unlinked then 'Новая карта: выберите для неё счёт'
    when public.mora_parse_payment_amount(p_amount) is null then 'Не получена положительная сумма'
    when coalesce(btrim(p_merchant),'') = '' then 'Не получено название продавца'
    when coalesce(p_currency,'') = '' then 'Не получена валюта покупки'
    when p_account is null or coalesce((p_account->>'archived')::boolean,false) then 'Счет недоступен'
    when p_account->>'currency' <> p_currency then 'Валюта покупки отличается от валюты счета' else null end
$$;

create function public.mora_capture_payment(p_token text, p_event_id uuid, p_amount text, p_currency text,
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
    if v_linked is not null then v_target := v_linked; else v_unlinked := true; end if;
  end if;

  select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=v_target;
  reason := public.mora_capture_reason(p_amount, p_currency, p_merchant, account, v_unlinked);
  insert into public.mora_captures(household_id,phone_token_id,event_id,account_id,merchant,amount_text,currency,occurred_at,state,reason,card_id)
    values(t.household_id,t.id,p_event_id,v_target,p_merchant,p_amount,p_currency,p_occurred_at,'pending',reason,v_card_id) returning * into capture;
  if reason is null then
    capture.transaction_id := public.mora_append_payment(t.household_id,capture.id,v_target,amount,p_currency,p_merchant,p_occurred_at,t.label);
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

-- Older senders keep working unchanged.
create or replace function public.mora_capture_payment(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz) returns jsonb
language sql security definer set search_path = '' as $$
  select public.mora_capture_payment(p_token, p_event_id, p_amount, p_currency, p_merchant, p_occurred_at, null::text)
$$;

create or replace function public.mora_list_pending(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'merchant',c.merchant,'amount',c.amount_text,'currency',c.currency,
    'account_id',c.account_id,'date',to_char(c.occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'reason',c.reason,'label',t.label,'card_id',c.card_id,'card',w.card,
    'card_linked',case when c.card_id is null then null else w.account_id is not null end) order by c.created_at desc),'[]'::jsonb)
    from public.mora_captures c join public.mora_phone_tokens t on t.id=c.phone_token_id
    left join public.mora_wallet_cards w on w.id=c.card_id
    where c.household_id=p_household_id and c.state='pending');
end $$;

create function public.mora_list_wallet_cards(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'card',w.card,'account_id',w.account_id,
    'token_id',t.id,'label',t.label,'default_account_id',t.account_id,
    'last_seen',to_char(w.last_seen_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'pending_count',(select count(*) from public.mora_captures c where c.card_id=w.id and c.state='pending'))
    order by t.label, w.card),'[]'::jsonb)
    from public.mora_wallet_cards w join public.mora_phone_tokens t on t.id=w.phone_token_id
    where w.household_id=p_household_id and t.revoked_at is null);
end $$;

-- Link (or unlink with null) a card. Its waiting purchases move to that account and get
-- a fresh reason; Mora then books complete ones exactly like any other Wallet purchase.
create function public.mora_link_wallet_card(p_household_id uuid, p_card_id uuid, p_account_id uuid) returns integer
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
  for c in select * from public.mora_captures where card_id=w.id and state='pending' for update loop
    target := coalesce(p_account_id, (select account_id from public.mora_phone_tokens where id=c.phone_token_id));
    select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=target;
    update public.mora_captures set account_id=target,
      reason=public.mora_capture_reason(c.amount_text, c.currency, c.merchant, account, p_account_id is null)
      where id=c.id;
    moved := moved + 1;
  end loop;
  return moved;
end $$;

-- A first review chooses the card account and records the purchase atomically.
create or replace function public.mora_review_capture(p_household_id uuid, p_capture_id uuid, p_transaction jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.mora_captures; snap jsonb; tx jsonb; account jsonb; destination jsonb; category jsonb;
  amount numeric; credited numeric; occurred timestamptz; conversion jsonb;
  original numeric; rate numeric; fee numeric; decimals integer;
begin
  perform public.mora_require_member(p_household_id);
  select snapshot into snap from public.mora_households where id=p_household_id for update;
  select * into c from public.mora_captures where id=p_capture_id and household_id=p_household_id for update;
  if c.id is null then raise exception 'Capture missing'; end if;
  -- A lost response or two reviewers must never append a second transaction.
  if c.state='recorded' then return public.mora_envelope(p_household_id); end if;
  if c.state<>'pending' then raise exception 'Capture no longer pending'; end if;
  if jsonb_typeof(p_transaction) is distinct from 'object' or octet_length(p_transaction::text)>64000 then
    raise exception 'Invalid transaction';
  end if;
  tx := p_transaction;
  if exists(select 1 from jsonb_object_keys(tx) k where k <> all(array[
    'id','date','merchant','amount','accountID','kind','note','tags','categoryID',
    'destinationAccountID','destinationAmount','externalID','conversion'])) then raise exception 'Unsupported transaction fields'; end if;
  if tx->>'kind' not in ('expense','income','transfer') or tx->>'kind' is null
    or jsonb_typeof(tx->'amount') is distinct from 'number'
    or jsonb_typeof(tx->'merchant') is distinct from 'string' or length(trim(tx->>'merchant')) not between 1 and 2000
    or jsonb_typeof(tx->'note') is distinct from 'string' or length(tx->>'note')>10000
    or jsonb_typeof(tx->'tags') is distinct from 'array'
    or jsonb_typeof(tx->'date') is distinct from 'string' then raise exception 'Invalid transaction fields'; end if;
  if jsonb_array_length(tx->'tags')>100 or exists(select 1 from jsonb_array_elements(tx->'tags') tag
    where jsonb_typeof(tag)<>'string' or length(tag#>>'{}')>100) then raise exception 'Invalid tags'; end if;
  amount := (tx->>'amount')::numeric;
  occurred := (tx->>'date')::timestamptz;
  if amount=0 or abs(amount)>999999999999 or not isfinite(occurred)
    or (tx->>'kind'='income' and amount<0) or (tx->>'kind'<>'income' and amount>0) then raise exception 'Invalid amount or date'; end if;
  select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=(tx->>'accountID')::uuid;
  if account is null or coalesce((account->>'archived')::boolean,false) then raise exception 'Account missing or archived'; end if;
  if nullif(tx->>'categoryID','') is not null then
    select cat into category from jsonb_array_elements(snap->'categories') cat where (cat->>'id')::uuid=(tx->>'categoryID')::uuid;
    if category is null or category->>'kind'<>tx->>'kind' or tx->>'kind'='transfer' then raise exception 'Invalid category'; end if;
  end if;
  if tx->>'kind'='transfer' then
    select a into destination from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=(tx->>'destinationAccountID')::uuid;
    if destination is null or destination->>'id'=account->>'id' or coalesce((destination->>'archived')::boolean,false)
      or jsonb_typeof(tx->'destinationAmount') is distinct from 'number' then raise exception 'Invalid transfer destination'; end if;
    credited := (tx->>'destinationAmount')::numeric;
    if credited<=0 or (destination->>'currency'=account->>'currency' and credited<>-amount) then raise exception 'Invalid transfer amount'; end if;
  elsif tx->>'destinationAccountID' is not null or tx->>'destinationAmount' is not null then
    raise exception 'Unexpected transfer fields';
  end if;
  conversion := tx->'conversion';
  if conversion is not null and conversion<>'null'::jsonb then
    if tx->>'kind'='transfer' or jsonb_typeof(conversion) is distinct from 'object'
      or conversion->>'accountCurrency' is distinct from account->>'currency'
      or coalesce(conversion->>'originalCurrency','') !~ '^[A-Z]{3}$'
      or conversion->>'originalCurrency'=account->>'currency'
      or jsonb_typeof(conversion->'originalAmount') is distinct from 'number'
      or jsonb_typeof(conversion->'rate') is distinct from 'number'
      or conversion->>'provider' is distinct from 'Visa'
      or conversion->>'date' is null then raise exception 'Invalid conversion'; end if;
    original := (conversion->>'originalAmount')::numeric;
    rate := (conversion->>'rate')::numeric;
    fee := coalesce((conversion->>'bankFeePercent')::numeric,0);
    if original*amount<=0 or rate<=0 or fee<0 or fee>100 or (original>0 and fee<>0)
      or not isfinite((conversion->>'date')::timestamptz) then raise exception 'Invalid conversion values'; end if;
    decimals := case when account->>'currency'=any(array['BIF','CLP','DJF','GNF','ISK','JPY','KMF','KRW','PYG','RWF','UGX','UYI','VND','VUV','XAF','XOF','XPF']) then 0
      when account->>'currency'=any(array['BHD','IQD','JOD','KWD','LYD','OMR','TND']) then 3
      when account->>'currency'=any(array['CLF','UYW']) then 4 else 2 end;
    if round(original*rate*(1+fee/100),decimals)<>amount then raise exception 'Converted amount differs'; end if;
  end if;
  if exists(select 1 from jsonb_array_elements(snap->'transactions') t
    where (t->>'id')::uuid=c.id or t->>'externalID'='wallet:'||c.id::text) then raise exception 'Wallet transaction already exists'; end if;
  tx := tx || jsonb_build_object('id',upper(c.id::text),'externalID','wallet:'||c.id::text,
                                'accountID',upper((tx->>'accountID')::uuid::text));
  snap := jsonb_set(snap,'{transactions}',(snap->'transactions')||jsonb_build_array(tx));
  perform public.mora_validate_snapshot(snap);
  -- Link only after review validation succeeds, in the same transaction and
  -- household lock as booking. No other Mac can auto-book this capture first.
  if c.card_id is not null and exists(select 1 from public.mora_wallet_cards
      where id=c.card_id and account_id is null) then
    perform public.mora_link_wallet_card(p_household_id, c.card_id, (tx->>'accountID')::uuid);
  end if;
  update public.mora_households set snapshot=snap,version=version+1,updated_at=now() where id=p_household_id;
  update public.mora_captures set state='recorded',transaction_id=c.id,reason=null where id=c.id;
  return public.mora_envelope(p_household_id);
end $$;

revoke all on function public.mora_normalize_card(text) from public, anon, authenticated;
revoke all on function public.mora_capture_reason(text,text,text,jsonb,boolean) from public, anon, authenticated;
revoke all on function public.mora_capture_payment(text,uuid,text,text,text,timestamptz,text) from public, anon, authenticated;
revoke all on function public.mora_capture_payment(text,uuid,text,text,text,timestamptz) from public, anon, authenticated;
revoke all on function public.mora_list_pending(uuid) from public, anon, authenticated;
revoke all on function public.mora_list_wallet_cards(uuid) from public, anon, authenticated;
revoke all on function public.mora_link_wallet_card(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.mora_capture_payment(text,uuid,text,text,text,timestamptz,text) to anon, authenticated;
grant execute on function public.mora_capture_payment(text,uuid,text,text,text,timestamptz) to anon, authenticated;
grant execute on function public.mora_list_pending(uuid), public.mora_list_wallet_cards(uuid),
  public.mora_link_wallet_card(uuid,uuid,uuid) to authenticated;
commit;
notify pgrst, 'reload schema';
