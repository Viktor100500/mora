begin;

alter table public.mora_captures drop constraint mora_captures_state_check;
alter table public.mora_captures add constraint mora_captures_state_check
  check (state in ('pending','recorded','dismissed','duplicate'));

-- Compare the purchase price, before conversion and bank fees. Card labels can
-- differ between Wallet Transaction and Notification; the routed account is stable.
-- An ambiguous match stays in review, as do purchases without complete evidence.
create function public.mora_wallet_duplicate_transaction(c public.mora_captures, snap jsonb) returns uuid
language sql stable set search_path = '' as $$
  select case when count(*)=1 then (array_agg((tx->>'id')::uuid))[1] end
  from jsonb_array_elements(snap->'transactions') tx
  join jsonb_array_elements(snap->'accounts') a on a->>'id'=tx->>'accountID'
  where c.wallet_notification and c.state='pending'
    and public.mora_parse_payment_amount(c.amount_text)>0 and c.currency<>''
    and regexp_replace(lower(c.merchant),'[^[:alnum:]]','','g')<>''
    and tx->>'kind'='expense' and (tx->>'id')::uuid<>c.id
    and (tx->>'accountID')::uuid=c.account_id
    and abs(extract(epoch from ((tx->>'date')::timestamptz-c.occurred_at)))<=120
    and regexp_replace(lower(tx->>'merchant'),'[^[:alnum:]]','','g')=
        regexp_replace(lower(c.merchant),'[^[:alnum:]]','','g')
    and coalesce(tx->'conversion'->>'originalCurrency',a->>'currency')=c.currency
    and -coalesce(tx->'conversion'->>'originalAmount',tx->'sameCurrencyFee'->>'originalAmount',tx->>'amount')::numeric=
        public.mora_parse_payment_amount(c.amount_text)
$$;
revoke all on function public.mora_wallet_duplicate_transaction(public.mora_captures,jsonb) from public,anon,authenticated;

create function public.mora_match_wallet_notification() returns trigger
language plpgsql set search_path = '' as $$
declare snap jsonb; matched uuid;
begin
  if new.wallet_notification and new.state='pending' then
    select snapshot into snap from public.mora_households where id=new.household_id for update;
    matched := public.mora_wallet_duplicate_transaction(new,snap);
    if matched is not null then
      new.state := 'duplicate'; new.transaction_id := matched; new.reason := null;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.mora_match_wallet_notification() from public,anon,authenticated;
create trigger mora_match_wallet_notification before insert or update on public.mora_captures
  for each row execute function public.mora_match_wallet_notification();

-- Handles the reverse arrival order and later cloud/manual/imported transactions.
create function public.mora_reconcile_wallet_notifications() returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.mora_captures c set merchant=c.merchant
    where c.household_id=new.id and c.wallet_notification and c.state='pending';
  return new;
end $$;
revoke all on function public.mora_reconcile_wallet_notifications() from public,anon,authenticated;
create trigger mora_reconcile_wallet_notifications after update of snapshot on public.mora_households
  for each row when (old.snapshot->'transactions' is distinct from new.snapshot->'transactions')
  execute function public.mora_reconcile_wallet_notifications();

create or replace function public.mora_capture_wallet_review(p_token text, p_event_id uuid, p_amount text, p_currency text,
  p_merchant text, p_occurred_at timestamptz, p_card text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb; current_state text;
begin
  if length(coalesce(p_merchant,'')) > 300 then raise exception 'Invalid payment input'; end if;
  result := public.mora_capture_payment(p_token, p_event_id, p_amount, p_currency, '', p_occurred_at, p_card);
  if (result->>'duplicate')::boolean then return result; end if;
  if result->>'state' is distinct from 'pending' then raise exception 'Expected a pending Wallet capture'; end if;
  update public.mora_captures set merchant=trim(coalesce(p_merchant,'')), wallet_notification=true
    where id=(result->>'id')::uuid;
  select state into current_state from public.mora_captures where id=(result->>'id')::uuid;
  return (result - 'reason') || jsonb_build_object('state',current_state,'duplicate',current_state='duplicate');
end $$;


-- Journals keep the evidence, while the normal pending RPC excludes duplicates.
create function public.mora_list_capture_duplicates(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.mora_require_member(p_household_id);
  return (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'event_id',c.event_id,
    'transaction_id',c.transaction_id,'merchant',c.merchant,
    'date',to_char(c.occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')) order by c.created_at desc),'[]'::jsonb)
    from public.mora_captures c where c.household_id=p_household_id
      and c.state='duplicate' and c.created_at>=now()-interval '14 days');
end $$;
revoke all on function public.mora_list_capture_duplicates(uuid) from public,anon,authenticated;
grant execute on function public.mora_list_capture_duplicates(uuid) to authenticated;

-- Reconcile existing reviews without modifying the ledger or its balances.
update public.mora_captures set merchant=merchant where wallet_notification and state='pending';
commit;
notify pgrst, 'reload schema';
