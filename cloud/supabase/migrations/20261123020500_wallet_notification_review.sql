begin;

alter table public.mora_captures add column wallet_notification boolean not null default false;

-- Reserve a pending capture through the normal phone-key and card routing path.
-- With the merchant withheld, that path cannot book it. Restore the parsed
-- merchant in the same transaction, before the capture is visible to clients.
create function public.mora_capture_wallet_review(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz, p_card text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  if length(coalesce(p_merchant,'')) > 300 then raise exception 'Invalid payment input'; end if;
  result := public.mora_capture_payment(p_token, p_event_id, p_amount, p_currency, '', p_occurred_at, p_card);
  if (result->>'duplicate')::boolean then return result; end if;
  if result->>'state' is distinct from 'pending' then raise exception 'Expected a pending Wallet capture'; end if;
  update public.mora_captures set merchant=trim(coalesce(p_merchant,'')), wallet_notification=true
    where id=(result->>'id')::uuid;
  return result - 'reason';
end $$;

revoke all on function public.mora_capture_wallet_review(text,uuid,text,text,text,timestamptz,text) from public, anon, authenticated;
grant execute on function public.mora_capture_wallet_review(text,uuid,text,text,text,timestamptz,text) to anon, authenticated;

create or replace function public.mora_list_pending(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'merchant',c.merchant,'amount',c.amount_text,'currency',c.currency,
    -- Older clients only auto-book against an active account. Always let them
    -- review these captures manually, even when the card is already linked.
    'account_id',case when c.wallet_notification then '00000000-0000-0000-0000-000000000000'::uuid else c.account_id end,
    'review_account_id',case when c.wallet_notification then c.account_id end,
    'event_id',case when c.wallet_notification then c.event_id end,
    'wallet_notification',c.wallet_notification,
    'date',to_char(c.occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'reason',case when c.wallet_notification and c.merchant <> '' then 'Проверьте покупку из уведомления Wallet'
      when c.wallet_notification then 'Wallet не передал продавца' else c.reason end,
    'label',t.label,'card_id',c.card_id,'card',w.card,
    'card_required',t.require_card,'card_linked',case when c.card_id is null then null else w.account_id is not null end)
    order by c.created_at desc),'[]'::jsonb)
    from public.mora_captures c join public.mora_phone_tokens t on t.id=c.phone_token_id
    left join public.mora_wallet_cards w on w.id=c.card_id
    where c.household_id=p_household_id and c.state='pending');
end $$;

commit;
notify pgrst, 'reload schema';
