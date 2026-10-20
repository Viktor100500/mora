-- Collect every successfully booked, unbatched Wallet purchase available now.
-- The household lock makes concurrent Macs and retries share one import batch.
begin;
create function public.mora_collect_wallet_import(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare snap jsonb; imports jsonb; purchases jsonb; batch jsonb; batch_id uuid;
  ids text[]; collected_at text;
begin
  perform public.mora_require_member(p_household_id);
  select snapshot into snap from public.mora_households where id=p_household_id for update;
  imports := case when jsonb_typeof(snap->'imports')='array' then snap->'imports' else '[]'::jsonb end;
  select array_agg(lower(t->>'id') order by n) into ids
    from jsonb_array_elements(snap->'transactions') with ordinality as rows(t,n)
    where nullif(t->>'importBatchID','') is null
      and exists(select 1 from public.mora_captures c where c.household_id=p_household_id and c.state='recorded'
        and c.transaction_id::text=lower(t->>'id') and t->>'externalID'='wallet:'||c.id::text)
      and not exists(select 1 from jsonb_array_elements(imports) b,
        jsonb_array_elements(b->'transactions') old where lower(old->>'id')=lower(t->>'id'));
  if ids is null then
    return jsonb_build_object('envelope',public.mora_envelope(p_household_id),'batch_id',null);
  end if;
  batch_id := gen_random_uuid();
  collected_at := to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"');
  select jsonb_agg(t||jsonb_build_object('importBatchID',upper(batch_id::text)) order by n) into purchases
    from jsonb_array_elements(snap->'transactions') with ordinality as rows(t,n) where lower(t->>'id')=any(ids);
  batch := jsonb_build_object('id',upper(batch_id::text),'filename','Покупки из Apple Shortcuts','source','Apple Shortcuts',
    'createdAt',collected_at,'totalRows',cardinality(ids),'excluded',0,'duplicates',0,'invalid',0,'transactions',purchases,
    'accountNames',coalesce((select jsonb_object_agg(upper(a->>'id'),a->>'name') from jsonb_array_elements(snap->'accounts') a),'{}'::jsonb),
    'currencies',coalesce((select jsonb_object_agg(upper(a->>'id'),a->>'currency') from jsonb_array_elements(snap->'accounts') a),'{}'::jsonb),
    'categoryNames',coalesce((select jsonb_object_agg(upper(c->>'id'),c->>'name') from jsonb_array_elements(snap->'categories') c),'{}'::jsonb));
  snap := jsonb_set(snap,'{transactions}',(select jsonb_agg(case when lower(t->>'id')=any(ids)
    then t||jsonb_build_object('importBatchID',upper(batch_id::text)) else t end order by n)
    from jsonb_array_elements(snap->'transactions') with ordinality as rows(t,n)));
  snap := jsonb_set(snap,'{imports}',imports||jsonb_build_array(batch));
  perform public.mora_validate_snapshot(snap);
  update public.mora_households set snapshot=snap,version=version+1,updated_at=now() where id=p_household_id;
  return jsonb_build_object('envelope',public.mora_envelope(p_household_id),'batch_id',batch_id);
end $$;
revoke all on function public.mora_collect_wallet_import(uuid) from public,anon,authenticated;
grant execute on function public.mora_collect_wallet_import(uuid) to authenticated;
commit;
