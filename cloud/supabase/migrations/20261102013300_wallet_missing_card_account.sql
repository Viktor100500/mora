-- Missing-card captures wait for an explicit account choice on old clients too.
begin;
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
    if v_linked is not null then v_target := v_linked; else v_unlinked := true; end if;
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

commit;
notify pgrst, 'reload schema';
