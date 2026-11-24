begin;

-- One purchase can reach Mora twice from one iPhone: as a Wallet notification
-- ("Uber", issuer label as the card) and as a bank-app message or Wallet
-- Transaction run ("UBER *BLUESTONELANE SAN FRANCISCOUS", "Moja mBanka ··5109").
-- The names share a word or one contains the other; exact equality missed them.
create or replace function public.mora_merchant_names_match(a text, b text) returns boolean
language sql immutable set search_path = '' as $$
  select x<>'' and y<>'' and (x=y
    or (least(length(x),length(y))>=3 and (position(x in y)>0 or position(y in x)>0))
    or exists(select 1 from regexp_split_to_table(lower(a),'[^[:alnum:]]+') w1
              join regexp_split_to_table(lower(b),'[^[:alnum:]]+') w2 on w1=w2
              where length(w1)>=4 and w1 ~ '[[:alpha:]]'))
  from (select regexp_replace(lower(coalesce(a,'')),'[^[:alnum:]]','','g') x,
               regexp_replace(lower(coalesce(b,'')),'[^[:alnum:]]','','g') y) n
$$;
revoke all on function public.mora_merchant_names_match(text,text) from public,anon,authenticated;

-- A pending capture duplicates one expense with the same original price and
-- currency within two minutes and a matching merchant, when either
--   * it is a Wallet notification and the expense is in its routed account, or
--   * the expense was booked from a capture of the other channel (notification
--     versus bank message / Wallet Transaction) sent by the same phone key.
--     Card labels of one card route to different accounts, so the account is
--     not compared here; the capture's own merchant is accepted besides the
--     booked one, which the reviewer may have renamed.
-- Ambiguity stays in review.
create or replace function public.mora_wallet_duplicate_transaction(c public.mora_captures, snap jsonb) returns uuid
language sql stable set search_path = '' as $$
  select case when count(*)=1 then (array_agg((tx->>'id')::uuid))[1] end
  from jsonb_array_elements(snap->'transactions') tx
  join jsonb_array_elements(snap->'accounts') a on a->>'id'=tx->>'accountID'
  left join public.mora_captures o
    on o.id = case when tx->>'externalID' ~* '^wallet:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   then substr(tx->>'externalID',8)::uuid end
   and o.id<>c.id and o.state='recorded' and o.phone_token_id=c.phone_token_id
   and o.wallet_notification<>c.wallet_notification
  where c.state='pending'
    -- One expense absorbs at most one duplicate per channel.
    and not exists(select 1 from public.mora_captures d where d.id<>c.id and d.state='duplicate'
      and d.household_id=c.household_id and d.transaction_id=(tx->>'id')::uuid
      and d.wallet_notification=c.wallet_notification)
    and public.mora_parse_payment_amount(c.amount_text)>0 and c.currency<>''
    and regexp_replace(lower(c.merchant),'[^[:alnum:]]','','g')<>''
    and tx->>'kind'='expense' and (tx->>'id')::uuid<>c.id
    and ((c.wallet_notification and (tx->>'accountID')::uuid=c.account_id) or o.id is not null)
    and abs(extract(epoch from ((tx->>'date')::timestamptz-c.occurred_at)))<=120
    and (public.mora_merchant_names_match(tx->>'merchant',c.merchant)
         or (o.id is not null and public.mora_merchant_names_match(o.merchant,c.merchant)))
    and coalesce(tx->'conversion'->>'originalCurrency',a->>'currency')=c.currency
    and -coalesce(tx->'conversion'->>'originalAmount',tx->'sameCurrencyFee'->>'originalAmount',tx->>'amount')::numeric=
        public.mora_parse_payment_amount(c.amount_text)
$$;
revoke all on function public.mora_wallet_duplicate_transaction(public.mora_captures,jsonb) from public,anon,authenticated;

-- Every pending phone capture is checked, not only Wallet notifications.
create or replace function public.mora_match_wallet_notification() returns trigger
language plpgsql set search_path = '' as $$
declare snap jsonb; matched uuid;
begin
  if new.state='pending' and new.phone_token_id is not null then
    select snapshot into snap from public.mora_households where id=new.household_id for update;
    matched := public.mora_wallet_duplicate_transaction(new,snap);
    if matched is not null then
      new.state := 'duplicate'; new.transaction_id := matched; new.reason := null;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.mora_match_wallet_notification() from public,anon,authenticated;

-- Booking one side of a pair closes the other side's pending review.
create or replace function public.mora_reconcile_wallet_notifications() returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.mora_captures c set merchant=c.merchant
    where c.household_id=new.id and c.state='pending' and c.phone_token_id is not null;
  return new;
end $$;
revoke all on function public.mora_reconcile_wallet_notifications() from public,anon,authenticated;

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

update public.mora_captures set merchant=merchant where state='pending' and phone_token_id is not null;
commit;
notify pgrst, 'reload schema';
