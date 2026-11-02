-- Configure a phone and all card/account bindings before exporting its shortcut.
-- Existing keys retain their legacy fallback; newly configured keys require a card.
begin;
alter table public.mora_phone_tokens add column require_card boolean not null default false;

create function public.mora_create_wallet_setup(p_household_id uuid, p_label text, p_cards jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare snap jsonb; entry jsonb; account jsonb; name text; issued jsonb; token_id uuid;
begin
  perform public.mora_require_member(p_household_id);
  select snapshot into snap from public.mora_households where id=p_household_id for update;
  if jsonb_typeof(p_cards) is distinct from 'array' then raise exception 'Select Wallet cards and accounts'; end if;
  if jsonb_array_length(p_cards) not between 1 and 50 then raise exception 'Select 1 to 50 Wallet cards'; end if;
  for entry in select * from jsonb_array_elements(p_cards) loop
    if jsonb_typeof(entry->'card') is distinct from 'string' or length(entry->>'card')>200
      or public.mora_normalize_card(entry->>'card') is null then raise exception 'Enter the card name from Wallet'; end if;
    select a into account from jsonb_array_elements(snap->'accounts') a
      where (a->>'id')::uuid=(entry->>'account_id')::uuid;
    if account is null or coalesce((account->>'archived')::boolean,false) then raise exception 'Select an active shared account'; end if;
  end loop;
  if exists(select 1 from jsonb_array_elements(p_cards) e group by lower(public.mora_normalize_card(e->>'card')) having count(*)>1) then
    raise exception 'Wallet card names must be unique';
  end if;
  issued := public.mora_create_phone_token(p_household_id, (p_cards->0->>'account_id')::uuid, p_label);
  token_id := (issued->>'id')::uuid;
  update public.mora_phone_tokens set require_card=true where id=token_id;
  for entry in select * from jsonb_array_elements(p_cards) loop
    name := public.mora_normalize_card(entry->>'card');
    insert into public.mora_wallet_cards(household_id,phone_token_id,card_key,card,account_id)
      values(p_household_id,token_id,lower(name),name,(entry->>'account_id')::uuid);
  end loop;
  return issued;
end $$;
revoke all on function public.mora_create_wallet_setup(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.mora_create_wallet_setup(uuid,text,jsonb) to authenticated;

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

create or replace function public.mora_list_pending(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'merchant',c.merchant,'amount',c.amount_text,'currency',c.currency,
    'account_id',c.account_id,'date',to_char(c.occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'reason',c.reason,'label',t.label,'card_id',c.card_id,'card',w.card,
    'card_required',t.require_card,'card_linked',case when c.card_id is null then null else w.account_id is not null end) order by c.created_at desc),'[]'::jsonb)
    from public.mora_captures c join public.mora_phone_tokens t on t.id=c.phone_token_id
    left join public.mora_wallet_cards w on w.id=c.card_id
    where c.household_id=p_household_id and c.state='pending');
end $$;

commit;
notify pgrst, 'reload schema';
