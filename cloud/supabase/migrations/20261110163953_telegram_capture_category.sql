-- Purchases from the Telegram form in another currency wait in the inbox for
-- the Visa conversion in Mora. They now keep the category and note chosen in
-- the form: mora_review_capture uses that category when the review picks none
-- (a category chosen while reviewing always wins) and puts the note first.
-- Apply after telegram_bot_settings.
begin;
alter table public.mora_captures add column category_id uuid, add column note text
  check (note is null or length(note) <= 500);

create or replace function public.mora_phone_add_purchase(p_token text, p_event_id uuid, p_account_id uuid, p_amount numeric,
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
  -- The form's category and note wait with the purchase for the Visa conversion in Mora.
  insert into public.mora_captures(household_id,phone_token_id,event_id,account_id,merchant,amount_text,currency,occurred_at,state,reason,category_id,note)
    values(t.household_id,t.id,p_event_id,p_account_id,p_merchant,amount_text,p_currency,p_occurred_at,'pending',reason,
      (category->>'id')::uuid,nullif(p_note,'')) returning * into capture;
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
    -- The form takes the purchase price; add the account's fee once, as for Apple Pay.
    if coalesce((account->>'sameCurrencyFeePercent')::numeric, 0) > 0 then
      if (account->>'sameCurrencyFeePercent')::numeric > 100 then raise exception 'Invalid purchase fee'; end if;
      tx := tx || jsonb_build_object('sameCurrencyFee', jsonb_build_object('originalAmount', -p_amount,
        'percent', (account->>'sameCurrencyFeePercent')::numeric),
        'amount', round(-p_amount * (1 + (account->>'sameCurrencyFeePercent')::numeric / 100),
                        public.mora_currency_decimals(account->>'currency')));
    end if;
    snap := jsonb_set(snap, '{transactions}', (snap->'transactions') || jsonb_build_array(tx));
    perform public.mora_validate_snapshot(snap);
    update public.mora_households set snapshot=snap, version=version+1, updated_at=now() where id=t.household_id;
    update public.mora_captures set state='recorded', transaction_id=capture.id where id=capture.id;
    capture.state := 'recorded';
  end if;
  return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',false,'reason',reason,
    'account',account->>'name','category',category->>'name');
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
  if c.state='recorded' then return public.mora_envelope(p_household_id); end if;
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
    decimals := case when account->>'currency'=any(array['BIF','CLP','DJF','GNF','ISK','JPY','KMF','KRW','PYG','RWF','UGX','UYI','VND','VUV','XAF','XOF','XPF']) then 0
      when account->>'currency'=any(array['BHD','IQD','JOD','KWD','LYD','OMR','TND']) then 3
      when account->>'currency'=any(array['CLF','UYW']) then 4 else 2 end;
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
  update public.mora_households set snapshot=snap,version=version+1,updated_at=now() where id=p_household_id;
  update public.mora_captures set state='recorded',transaction_id=c.id,reason=null where id=c.id;
  return public.mora_envelope(p_household_id);
end $$;

revoke all on function public.mora_phone_add_purchase(text,uuid,uuid,numeric,text,text,uuid,text,timestamptz),
  public.mora_review_capture(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.mora_phone_add_purchase(text,uuid,uuid,numeric,text,text,uuid,text,timestamptz) to anon, authenticated;
grant execute on function public.mora_review_capture(uuid,uuid,jsonb) to authenticated;
commit;
notify pgrst, 'reload schema';
