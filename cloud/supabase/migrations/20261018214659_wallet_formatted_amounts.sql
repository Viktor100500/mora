-- Accept formatted Wallet amounts without inferring a currency from its symbol.
-- Preserve captured source text; existing inbox entries still require review.
begin;

create function public.mora_parse_payment_amount(p_input text) returns numeric
language plpgsql immutable set search_path = '' as $$
declare value text; stripped text; amount numeric;
  whitespace text := E' \t\n\r' || chr(160) || chr(8239);
begin
  if p_input is null or length(p_input) > 64 then return null; end if;
  value := btrim(p_input, whitespace);
  stripped := regexp_replace(value, '^([$€£¥₽]|USD|EUR|GBP|RUB|JPY|CAD|AUD|CHF|CNY)', '', 'i');
  if stripped <> value then
    value := btrim(stripped, whitespace);
  else
    value := btrim(regexp_replace(value, '([$€£¥₽]|USD|EUR|GBP|RUB|JPY|CAD|AUD|CHF|CNY)$', '', 'i'), whitespace);
  end if;
  -- Group separators are accepted only when every group contains three digits.
  if value ~ '^[0-9]{1,3}(,[0-9]{3})+\.[0-9]{1,6}$' then
    value := replace(value, ',', '');
  elsif value ~ '^[0-9]{1,3}(\.[0-9]{3})+,[0-9]{1,6}$' then
    value := replace(value, '.', '');
  elsif value ~ '^[0-9]{1,3}([   ][0-9]{3})+([.,][0-9]{1,6})?$' then
    value := regexp_replace(value, '[   ]', '', 'g');
  end if;
  if value !~ '^[0-9]{1,12}([.,][0-9]{1,6})?$' then return null; end if;
  amount := replace(value, ',', '.')::numeric;
  if amount <= 0 or amount > 999999999999 then return null; end if;
  return amount;
end $$;
revoke all on function public.mora_parse_payment_amount(text) from public, anon, authenticated;

create or replace function public.mora_capture_payment(p_token text, p_event_id uuid, p_amount text, p_currency text,
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
  return jsonb_build_object('id',capture.id,'state',capture.state,'duplicate',false,'reason',reason);
end $$;

-- Repair only the misleading reason; never create transactions from old captures.
update public.mora_captures c
set reason = case
  when trim(c.merchant) = '' then 'Не получено название продавца'
  when trim(c.currency) = '' then 'Не получена валюта покупки'
  when not exists (
    select 1 from jsonb_array_elements(h.snapshot->'accounts') a
    where (a->>'id')::uuid = c.account_id and not coalesce((a->>'archived')::boolean, false)
  ) then 'Счет недоступен'
  when not exists (
    select 1 from jsonb_array_elements(h.snapshot->'accounts') a
    where (a->>'id')::uuid = c.account_id and a->>'currency' = c.currency
  ) then 'Валюта покупки отличается от валюты счета'
  else 'Проверьте покупку'
end
from public.mora_households h
where h.id = c.household_id and c.state = 'pending'
  and c.reason = 'Не получена положительная сумма'
  and public.mora_parse_payment_amount(c.amount_text) is not null;

commit;
