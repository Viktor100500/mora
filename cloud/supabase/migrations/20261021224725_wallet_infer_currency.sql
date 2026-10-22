-- Infer a missing Wallet currency from explicit ISO codes and currency symbols
-- included in the formatted amount. A bare dollar sign follows Mora's existing
-- Wallet rule and means USD; ambiguous pound and yen symbols remain unknown.
begin;

create or replace function public.mora_parse_payment_currency(p_input text) returns text
language plpgsql immutable set search_path = '' as $$
declare value text; code text;
  whitespace text := E' \t\n\r' || chr(160) || chr(8239);
begin
  if p_input is null or length(p_input) > 64 then return null; end if;
  value := upper(btrim(p_input, whitespace));
  code := substring(value from '^(USD|EUR|GBP|RUB|JPY|CAD|AUD|CHF|CNY)');
  if code is null then code := substring(value from '(USD|EUR|GBP|RUB|JPY|CAD|AUD|CHF|CNY)$'); end if;
  if code is not null then return code; end if;
  if left(value,1)='$' or right(value,1)='$' then return 'USD'; end if;
  if left(value,1)='€' or right(value,1)='€' then return 'EUR'; end if;
  if left(value,1)='₽' or right(value,1)='₽' then return 'RUB'; end if;
  return null;
end $$;
revoke all on function public.mora_parse_payment_currency(text) from public, anon, authenticated;

create or replace function public.mora_capture_payment(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t public.mora_phone_tokens; capture public.mora_captures; snap jsonb; account jsonb;
  amount numeric; reason text; label text; currency_inferred boolean := false;
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
  if p_currency = '' then
    p_currency := coalesce(public.mora_parse_payment_currency(p_amount),'');
    currency_inferred := p_currency <> '';
  end if;
  amount := public.mora_parse_payment_amount(p_amount);
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
  return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',false,
    'reason',case when currency_inferred and reason='Валюта покупки отличается от валюты счета' then null else reason end,
    'currency',nullif(p_currency,''),'currency_inferred',currency_inferred,
    'next_step',case when currency_inferred and reason='Валюта покупки отличается от валюты счета' then 'mora_conversion' else null end);
end $$;

commit;
