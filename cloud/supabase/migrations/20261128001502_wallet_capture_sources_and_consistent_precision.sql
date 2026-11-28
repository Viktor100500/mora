begin;

-- Captures are immutable input evidence; only server-confirmed transactions affect balances.
-- The old boolean could not distinguish Wallet Transaction from a bank message.
alter table public.mora_captures add column capture_source text not null default 'legacy'
  check (capture_source in ('legacy','wallet_transaction','wallet_notification','bank_sms','bank_notification','bank_message'));
update public.mora_captures set capture_source='wallet_notification' where wallet_notification;

-- Known processor names for the same transit operator. All other merchants keep
-- the existing conservative match; price, currency, phone and time must also match.
create function public.mora_merchant_identity(merchant text) returns text
language sql immutable set search_path = '' as $$
  select case
    when compact like 'mtanyct%' or compact='metropolitantransportationauthority' then 'mta nyct'
    when compact like 'pathtapp%' or compact='portauthorityofnewyorknewjersey' then 'path tapp'
    else merchant end
  from (select regexp_replace(lower(coalesce(merchant,'')),'[^[:alnum:]]','','g') compact) n
$$;
revoke all on function public.mora_merchant_identity(text) from public,anon,authenticated;

create or replace function public.mora_wallet_duplicate_transaction(c public.mora_captures, snap jsonb) returns uuid
language sql stable set search_path = '' as $$
  select case when count(*)=1 then (array_agg((tx->>'id')::uuid))[1] end
  from jsonb_array_elements(snap->'transactions') tx
  join jsonb_array_elements(snap->'accounts') a on a->>'id'=tx->>'accountID'
  left join public.mora_captures o
    on o.id = case when tx->>'externalID' ~* '^wallet:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   then substr(tx->>'externalID',8)::uuid end
   and o.household_id=c.household_id and o.id<>c.id and o.state='recorded' and o.phone_token_id=c.phone_token_id
   and (o.wallet_notification<>c.wallet_notification or
     (o.capture_source<>c.capture_source and o.capture_source<>'legacy' and c.capture_source<>'legacy'))
  where c.state='pending'
    -- One expense absorbs at most one duplicate per channel.
    and not exists(select 1 from public.mora_captures d where d.id<>c.id and d.state='duplicate'
      and d.household_id=c.household_id and d.transaction_id=(tx->>'id')::uuid
      and d.capture_source=c.capture_source)
    and public.mora_parse_payment_amount(c.amount_text)>0 and c.currency<>''
    and regexp_replace(lower(c.merchant),'[^[:alnum:]]','','g')<>''
    and tx->>'kind'='expense' and (tx->>'id')::uuid<>c.id
    and ((c.wallet_notification and (tx->>'accountID')::uuid=c.account_id) or o.id is not null)
    and abs(extract(epoch from ((tx->>'date')::timestamptz-c.occurred_at)))<=120
    and (public.mora_merchant_names_match(public.mora_merchant_identity(tx->>'merchant'),public.mora_merchant_identity(c.merchant))
         or (o.id is not null and public.mora_merchant_names_match(public.mora_merchant_identity(o.merchant),public.mora_merchant_identity(c.merchant))))
    and coalesce(tx->'conversion'->>'originalCurrency',a->>'currency')=c.currency
    and -coalesce(tx->'conversion'->>'originalAmount',tx->'sameCurrencyFee'->>'originalAmount',tx->>'amount')::numeric=
        public.mora_parse_payment_amount(c.amount_text)
$$;
revoke all on function public.mora_wallet_duplicate_transaction(public.mora_captures,jsonb) from public,anon,authenticated;

create or replace function public.mora_capture_payment_from_source(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz, p_card text, p_source text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.mora_phone_tokens; capture public.mora_captures; snap jsonb; account jsonb;
  amount numeric; reason text; currency_inferred boolean := false;
  v_card text; v_card_id uuid; v_linked uuid; v_target uuid; v_unlinked boolean := false;
begin
  if p_source is null or p_source not in ('legacy','wallet_transaction','wallet_notification','bank_sms','bank_notification','bank_message') then
    raise exception 'Invalid capture source';
  end if;
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
  insert into public.mora_captures(household_id,phone_token_id,event_id,account_id,merchant,amount_text,currency,occurred_at,state,reason,card_id,capture_source,wallet_notification)
    values(t.household_id,t.id,p_event_id,v_target,p_merchant,p_amount,p_currency,p_occurred_at,'pending',reason,v_card_id,p_source,p_source='wallet_notification') returning * into capture;
  -- A purchase already booked from the paired notification is not booked again.
  if reason is null and capture.state='pending' then
    capture.transaction_id := public.mora_append_payment(t.household_id,capture.id,v_target,amount,p_currency,p_merchant,p_occurred_at,concat_ws(' · ',t.label,v_card));
    update public.mora_captures set state='recorded',transaction_id=capture.transaction_id where id=capture.id;
    capture.state := 'recorded';
  end if;
  return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',capture.state='duplicate',
    'reason',case when capture.state='duplicate' then null when currency_inferred and reason='Валюта покупки отличается от валюты счета' then null else reason end,
    'currency',nullif(p_currency,''),'currency_inferred',currency_inferred,
    'card',v_card,'card_linked',v_card is not null and not v_unlinked,
    'next_step',case when capture.state='duplicate' then null when v_unlinked then 'mora_link_card'
      when currency_inferred and reason='Валюта покупки отличается от валюты счета' then 'mora_conversion' else null end);
end $$;

-- Compatibility endpoint for installed older clients and Telegram. Unknown sources
-- remain unknown; the app-generated bank card suffix is the only legacy source marker.
create or replace function public.mora_capture_payment(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz, p_card text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  return public.mora_capture_payment_from_source(p_token,p_event_id,p_amount,p_currency,p_merchant,p_occurred_at,p_card,
    case when p_card ~ ' ··[0-9]{4}$' then 'bank_message' else 'legacy' end);
end $$;

revoke all on function public.mora_capture_payment_from_source(text,uuid,text,text,text,timestamptz,text,text) from public,anon,authenticated;
grant execute on function public.mora_capture_payment_from_source(text,uuid,text,text,text,timestamptz,text,text) to anon,authenticated;

create or replace function public.mora_capture_wallet_review(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz, p_card text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb; current_state text;
begin
  if length(coalesce(p_merchant,'')) > 300 then raise exception 'Invalid payment input'; end if;
  result := public.mora_capture_payment_from_source(p_token, p_event_id, p_amount, p_currency, '', p_occurred_at, p_card, 'wallet_notification');
  if (result->>'duplicate')::boolean then return result; end if;
  if result->>'state' is distinct from 'pending' then raise exception 'Expected a pending Wallet capture'; end if;
  update public.mora_captures set merchant=trim(coalesce(p_merchant,'')), wallet_notification=true
    where id=(result->>'id')::uuid;
  select state into current_state from public.mora_captures where id=(result->>'id')::uuid;
  return (result - 'reason') || jsonb_build_object('state',current_state,'duplicate',current_state='duplicate');
end $$;


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
  if c.state in ('recorded','duplicate') then return public.mora_envelope(p_household_id); end if;
  if c.state<>'pending' then raise exception 'Capture no longer pending'; end if;
  if jsonb_typeof(p_transaction) is distinct from 'object' or octet_length(p_transaction::text)>64000 then
    raise exception 'Invalid transaction';
  end if;
  tx := p_transaction;
  if exists(select 1 from jsonb_object_keys(tx) k where k <> all(array[
    'id','date','merchant','amount','accountID','kind','note','tags','categoryID',
    'destinationAccountID','destinationAmount','externalID','conversion','sameCurrencyFee'])) then raise exception 'Unsupported transaction fields'; end if;
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
  -- A Telegram purchase keeps the form's category when the review chose none,
  -- and the form's note goes in front of Mora's own note.
  if tx->>'kind'='expense' and nullif(tx->>'categoryID','') is null and c.category_id is not null then
    select cat into category from jsonb_array_elements(snap->'categories') cat
      where (cat->>'id')::uuid=c.category_id and cat->>'kind'='expense';
    if category is not null then tx := tx || jsonb_build_object('categoryID', category->>'id'); end if;
    category := null;
  end if;
  if nullif(btrim(c.note),'') is not null and position(c.note in tx->>'note') = 0 then
    tx := jsonb_set(tx, '{note}', to_jsonb(left(concat_ws(' · ', c.note, nullif(tx->>'note','')), 10000)));
  end if;
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
      or coalesce(conversion->>'provider','') not in ('Visa','Manual')
      or conversion->>'date' is null then raise exception 'Invalid conversion'; end if;
    original := (conversion->>'originalAmount')::numeric;
    rate := (conversion->>'rate')::numeric;
    fee := coalesce((conversion->>'bankFeePercent')::numeric,0);
    if original*amount<=0 or rate<=0 or fee<0 or fee>100 or (original>0 and fee<>0)
      or not isfinite((conversion->>'date')::timestamptz) then raise exception 'Invalid conversion values'; end if;
    decimals := public.mora_currency_decimals(account->>'currency');
    if round(original*rate*(1+fee/100),decimals)<>amount then raise exception 'Converted amount differs'; end if;
  end if;
  -- Validate the retained purchase price and the charged amount.
  if tx ? 'sameCurrencyFee' and tx->'sameCurrencyFee' <> 'null'::jsonb then
    if tx->>'kind' <> 'expense' or (conversion is not null and conversion <> 'null'::jsonb)
      or jsonb_typeof(tx->'sameCurrencyFee') is distinct from 'object'
      or jsonb_typeof(tx->'sameCurrencyFee'->'originalAmount') is distinct from 'number'
      or jsonb_typeof(tx->'sameCurrencyFee'->'percent') is distinct from 'number'
      or (tx->'sameCurrencyFee' ? 'roundingAdjustment' and coalesce((tx->'sameCurrencyFee'->>'roundingAdjustment')::numeric, 0) <> 0)
      then raise exception 'Invalid purchase fee'; end if;
    original := (tx->'sameCurrencyFee'->>'originalAmount')::numeric;
    fee := (tx->'sameCurrencyFee'->>'percent')::numeric;
    decimals := public.mora_currency_decimals(account->>'currency');
    if original >= 0 or fee <= 0 or fee > 100 or round(original*(1+fee/100),decimals) <> amount
      then raise exception 'Purchase fee differs from amount'; end if;
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
  -- Publish the capture state first inside this same locked transaction. The
  -- household's reconciliation trigger must see which source booked the expense.
  update public.mora_captures set state='recorded',transaction_id=c.id,reason=null where id=c.id;
  update public.mora_households set snapshot=snap,version=version+1,updated_at=now() where id=p_household_id;
  return public.mora_envelope(p_household_id);
end $$;

create or replace function public.mora_append_payment(p_household_id uuid, p_capture_id uuid, p_account_id uuid,
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
  -- A complete same-currency Wallet capture can be booked on the server.
  if coalesce((account->>'sameCurrencyFeePercent')::numeric, 0) > 0 then
    if (account->>'sameCurrencyFeePercent')::numeric > 100 then raise exception 'Invalid purchase fee'; end if;
    tx := tx || jsonb_build_object('sameCurrencyFee', jsonb_build_object('originalAmount', -p_amount,
      'percent', (account->>'sameCurrencyFeePercent')::numeric),
      'amount', round(-p_amount * (1 + (account->>'sameCurrencyFeePercent')::numeric / 100),
                      public.mora_currency_decimals(account->>'currency')));
  end if;
  if cat is not null then tx := tx || jsonb_build_object('categoryID',cat->>'id'); end if;
  snap := jsonb_set(snap, '{transactions}', (snap->'transactions') || jsonb_build_array(tx));
  perform public.mora_validate_snapshot(snap);
  update public.mora_captures set state='recorded',transaction_id=txid,reason=null where id=p_capture_id;
  update public.mora_households set snapshot = snap, version = version + 1, updated_at = now() where id = p_household_id;
  return txid;
end $$;

-- Refuse to publish a migration that diverges from the clients' calculation contract.
do $$ begin
  if public.mora_currency_decimals('RSD')<>2 or public.mora_currency_decimals('JPY')<>0
    or public.mora_currency_decimals('KWD')<>3 or public.mora_currency_decimals('CLF')<>4 then
    raise exception 'Currency precision contract differs';
  end if;
end $$;

commit;
notify pgrst, 'reload schema';
