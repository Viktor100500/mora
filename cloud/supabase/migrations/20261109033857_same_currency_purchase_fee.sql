-- Support version 5 without changing access rules.
create or replace function public.mora_validate_snapshot(p_snapshot jsonb) returns void
language plpgsql set search_path = '' as $$
declare k text;
begin
  if p_snapshot is null or jsonb_typeof(p_snapshot) <> 'object' or
     coalesce(p_snapshot->>'schemaVersion', '') not in ('4','5') or p_snapshot ? 'changeHistory' or
     jsonb_typeof(p_snapshot->'preferences') is distinct from 'object' or
     octet_length(p_snapshot::text) > 4000000 then
    raise exception 'Invalid or oversized snapshot';
  end if;
  foreach k in array array['accounts','categories','transactions','budgets','goals','recurring','rules'] loop
    if jsonb_typeof(p_snapshot->k) is distinct from 'array' then raise exception 'Invalid snapshot array'; end if;
  end loop;
  if p_snapshot->>'schemaVersion' = '4' and (
    exists(select 1 from jsonb_array_elements(p_snapshot->'accounts') a where a ? 'sameCurrencyFeePercent') or
    exists(select 1 from jsonb_array_elements(p_snapshot->'transactions') t where t ? 'sameCurrencyFee') or
    exists(select 1 from jsonb_array_elements(case when jsonb_typeof(p_snapshot->'imports') = 'array' then p_snapshot->'imports' else '[]'::jsonb end) b,
      lateral jsonb_array_elements(case when jsonb_typeof(b->'transactions') = 'array' then b->'transactions' else '[]'::jsonb end) t where t ? 'sameCurrencyFee')
  ) then raise exception 'Purchase fees require schema version 5'; end if;
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

create or replace function public.mora_agent_add_transactions(p_token text, p_transactions jsonb, p_source text default null,
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
      -- Agent inputs are purchase prices, so add the account fee once.
      if kind = 'expense' and coalesce(item->>'note', '') !~ E'(^|\\n)(Исходная покупка: |Original purchase: )'
        and coalesce((account->>'sameCurrencyFeePercent')::numeric, 0) > 0 then
        if (account->>'sameCurrencyFeePercent')::numeric > 100 then raise exception 'invalid purchase fee'; end if;
        tx := tx || jsonb_build_object('sameCurrencyFee', jsonb_build_object('originalAmount', -amount,
          'percent', (account->>'sameCurrencyFeePercent')::numeric),
          'amount', round(-amount * (1 + (account->>'sameCurrencyFeePercent')::numeric / 100),
                          public.mora_currency_decimals(account->>'currency')));
      end if;
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
  update public.mora_households set snapshot = snap, version = version + 1, updated_at = now() where id = p_household_id;
  return txid;
end $$;
