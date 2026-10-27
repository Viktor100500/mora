import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { initdb, postgres } from '@embedded-postgres/darwin-arm64';
import pg from 'pg';

// Disposable PostgreSQL on a private Unix socket. No network listener, no real data.
const here = path.dirname(fileURLToPath(import.meta.url));
const native = path.dirname(path.dirname(postgres));
for (const {source, target} of JSON.parse(await fs.readFile(path.join(native, 'pg-symlinks.json'), 'utf8'))) {
  const sourcePath = path.resolve(native, '..', source);
  const targetPath = path.resolve(native, '..', target);
  assert(sourcePath.startsWith(native + path.sep) && targetPath.startsWith(native + path.sep));
  try { await fs.symlink(path.relative(path.dirname(targetPath), sourcePath), targetPath); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
}
const runtime = await fs.mkdtemp('/private/tmp/mora-pg-');
const data = path.join(runtime, 'data');
let server; const clients = [];
const uuid = () => randomUUID();
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function connect(userID, role = 'authenticated') {
  const client = new pg.Client({host: runtime, user: 'postgres', database: 'postgres'});
  await client.connect(); clients.push(client);
  if (role) await client.query(`set role ${role}`);
  if (userID) await client.query("select set_config('request.jwt.claim.sub',$1,false)",[userID]);
  return client;
}
async function rpc(client, name, values = []) {
  const args = values.map((_,i) => '$' + (i+1)).join(',');
  return (await client.query(`select public.${name}(${args}) as value`,values)).rows[0].value;
}
async function denied(action, expectedCode = '42501') {
  await assert.rejects(action, error => error.code === expectedCode);
}
let checks = 0;
async function check(name, action) { await action(); checks++; console.log('PASS ' + name); }
try {
  execFileSync(initdb,['-D',data,'-U','postgres','--auth=trust','--encoding=UTF8','--locale=C'],{stdio:'pipe'});
  server = spawn(postgres,['-D',data,'-k',runtime,'-c',"listen_addresses=",'-c','fsync=off'],{stdio:['ignore','ignore','pipe']});
  let serverErrors = ''; server.stderr.on('data', chunk => { serverErrors += chunk; });
  for (let i=0;i<50;i++) {
    try { await fs.access(path.join(runtime,'.s.PGSQL.5432')); break; }
    catch { if (server.exitCode !== null) throw new Error(serverErrors); await pause(100); }
  }
  const admin = await connect(null,null);
  await admin.query(`create role anon nologin; create role authenticated nologin;
    create schema auth; create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as
      $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema auth to anon,authenticated;
    grant execute on function auth.uid() to anon,authenticated;`);
  const ownerID=uuid(), memberID=uuid(), outsiderID=uuid();
  await admin.query('insert into auth.users values ($1),($2),($3)',[ownerID,memberID,outsiderID]);
  await admin.query(await fs.readFile(path.join(here,'../supabase/migrations/202610120001_mora_cloud.sql'),'utf8'));
  const owner=await connect(ownerID), member=await connect(memberID), outsider=await connect(outsiderID), anon=await connect(null,'anon');
  const accountID=uuid().toUpperCase(), categoryID=uuid().toUpperCase();
  const snapshot={schemaVersion:4, accounts:[{id:accountID,name:'Shared test account',currency:'USD',kind:'checking',openingBalance:0,color:'green',archived:false}],
    categories:[{id:categoryID,name:'Cafe',icon:'cup.and.saucer',color:'orange',kind:'expense'}],transactions:[],budgets:[],goals:[],recurring:[],
    rules:[{id:uuid().toUpperCase(),keyword:'cafe',categoryID}],imports:[],preferences:{baseCurrency:'USD',rates:{USD:1},appearance:'system',automaticRates:true,showBudgets:false,showGoals:false,showRecurring:false,aiAgent:'chatgpt'}};
  let household=await rpc(owner,'mora_create_household',['Test household',snapshot]);
  const h=household.household_id;
  await check('non-members cannot read household or database tables',async()=>{
    await denied(()=>rpc(outsider,'mora_get_household',[h]));
    await denied(()=>anon.query('select * from public.mora_households'));
    await denied(()=>owner.query('select * from public.mora_phone_tokens'));
    await denied(()=>rpc(owner,'mora_envelope',[h]));
    await denied(()=>rpc(anon,'mora_get_household',[h]));
  });
  let invitation=await rpc(owner,'mora_create_invitation',[h]);
  await check('one-time invitation connects a separate account',async()=>{
    assert.equal((await rpc(member,'mora_join_household',[invitation])).household_id,h);
    await assert.rejects(()=>rpc(outsider,'mora_join_household',[invitation]));
    await denied(()=>rpc(member,'mora_create_invitation',[h]));
  });
  const phone1=await rpc(owner,'mora_create_phone_token',[h,accountID,'Owner iPhone']);
  const phone2=await rpc(member,'mora_create_phone_token',[h,accountID,'Member iPhone']);
  await check('phone tokens are hashed and scoped to their owner',async()=>{
    const stored=(await admin.query('select encode(token_hash,\'hex\') hash from public.mora_phone_tokens where id=$1',[phone1.id])).rows[0].hash;
    assert.notEqual(stored,phone1.token);
    assert.equal((await rpc(member,'mora_list_phone_tokens',[h])).length,1);
    assert.equal(await rpc(member,'mora_revoke_phone_token',[phone1.id]),false);
  });
  const event=uuid(), date='2026-10-12T12:00:00Z';
  const capture=(client,token,id,amount='12.50',currency='USD',merchant='Test cafe')=>rpc(client,'mora_capture_payment',[token,id,amount,currency,merchant,date]);
  await check('two concurrent phones append two payments with exact amounts',async()=>{
    const results=await Promise.all([capture(anon,phone1.token,event),capture(await connect(null,'anon'),phone2.token,uuid(),'0.10')]);
    assert(results.every(r=>r.state==='recorded'));
    household=await rpc(owner,'mora_get_household',[h]);
    assert.equal(household.snapshot.transactions.length,2);
    assert(household.snapshot.transactions.every(t=>t.categoryID===categoryID));
    assert.equal((await admin.query("select sum((t->>'amount')::numeric)::text amount from public.mora_households h,jsonb_array_elements(h.snapshot->'transactions') t where h.id=$1",[h])).rows[0].amount,'-12.60');
  });
  await check('retry with the same event ID never doubles a payment',async()=>{
    const result=await capture(anon,phone1.token,event);
    assert.equal(result.duplicate,true);
    assert.equal((await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length,2);
  });
  await check('stale desktop upload cannot erase a phone payment',async()=>{
    assert.equal(await rpc(owner,'mora_save_household',[h,1,snapshot]),false);
    assert.equal((await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length,2);
  });
  let incomplete, foreign;
  await check('missing amount and a foreign currency go to inbox without changing balances',async()=>{
    incomplete=await capture(anon,phone1.token,uuid(),'','USD');
    foreign=await capture(anon,phone2.token,uuid(),'100','EUR');
    assert.equal(incomplete.state,'pending'); assert.equal(foreign.state,'pending');
    assert.equal((await rpc(owner,'mora_list_pending',[h])).length,2);
    assert.equal((await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length,2);
  });
  await check('inbox resolution is exact and idempotent',async()=>{
    assert.equal(await rpc(member,'mora_resolve_capture',[h,foreign.id,accountID,'108.05','Foreign purchase',false]),true);
    assert.equal(await rpc(member,'mora_resolve_capture',[h,foreign.id,accountID,'108.05','Foreign purchase',false]),false);
    assert.equal(await rpc(owner,'mora_resolve_capture',[h,incomplete.id,accountID,'','',true]),true);
    assert.equal((await rpc(owner,'mora_list_pending',[h])).length,0);
    await denied(()=>rpc(outsider,'mora_resolve_capture',[h,incomplete.id,accountID,'1','Other',false]));
  });
  await check('decimal precision is preserved in server-created transactions',async()=>{
    const result=await capture(anon,phone1.token,uuid(),'123456789012.123456');
    const value=(await admin.query("select t->>'amount' amount from public.mora_households h,jsonb_array_elements(h.snapshot->'transactions') t where h.id=$1 and t->>'externalID'=$2",[h,'wallet:'+result.id])).rows[0].amount;
    assert.equal(value,'-123456789012.123456');
  });
  await check('revoked keys and forged keys cannot write',async()=>{
    assert.equal(await rpc(owner,'mora_revoke_phone_token',[phone1.id]),true);
    await denied(()=>capture(anon,phone1.token,uuid()));
    await denied(()=>capture(anon,'0'.repeat(64),uuid()));
  });
  await check('a member cannot bypass validation or call internal payment helpers',async()=>{
    const latest=await rpc(owner,'mora_get_household',[h]);
    await assert.rejects(()=>rpc(owner,'mora_save_household',[h,latest.version,{...snapshot,changeHistory:{undo:[]}}]));
    await denied(()=>rpc(anon,'mora_append_payment',[h,uuid(),accountID,10,'USD','Fake',date,'Fake']));
    await denied(()=>rpc(outsider,'mora_save_household',[h,latest.version,snapshot]));
  });
  await check('concurrent desktops get exactly one successful compare-and-swap',async()=>{
    const latest=await rpc(owner,'mora_get_household',[h]);
    // Preserve JSON numeric literals rather than round them through JavaScript Number.
    const raw=(await admin.query('select snapshot::text as value from public.mora_households where id=$1',[h])).rows[0].value;
    const r=await Promise.all([rpc(owner,'mora_save_household',[h,latest.version,raw]),rpc(member,'mora_save_household',[h,latest.version,raw])]);
    assert.equal(r.filter(Boolean).length,1);
  });
  // Keep the four-transaction Swift compatibility fixture stable as checks grow.
  const saved=(await admin.query('select snapshot::text as value from public.mora_households where id=$1',[h])).rows[0].value;
  const legacy = await capture(anon,phone2.token,uuid(),'$31.54','');
  const beforeMigration = (await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length;
  const migrations = (await fs.readdir(path.join(here,'../supabase/migrations'))).filter(name => name.endsWith('.sql')).sort();
  for (const migration of migrations.filter(name => name !== '202610120001_mora_cloud.sql')) {
    await admin.query(await fs.readFile(path.join(here,'../supabase/migrations',migration),'utf8'));
  }
  await check('formatted amount migration repairs old reasons without posting expenses',async()=>{
    const pending=(await rpc(owner,'mora_list_pending',[h])).find(c => c.id === legacy.id);
    assert.equal(pending.amount,'$31.54');
    assert.equal(pending.currency,'');
    assert.equal(pending.reason,'Не получена валюта покупки');
    assert.equal((await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length,beforeMigration);
    await rpc(owner,'mora_resolve_capture',[h,legacy.id,accountID,'','',true]);
  });
  await check('Wallet currency symbols and valid grouping preserve exact numeric amounts',async()=>{
    for (const [input,expected] of [['$31.54','31.54'],['31,54 €','31.54'],['USD 31.54','31.54'],
      ['$1,234.56','1234.56'],['1.234,56 €','1234.56'],['1\u202f234,56 ₽','1234.56'],['123456789012.123456','123456789012.123456']]) {
      const result=await capture(anon,phone2.token,uuid(),input,'USD');
      assert.equal(result.state,'recorded',input);
      const stored=(await admin.query("select t->>'amount' amount from public.mora_households h,jsonb_array_elements(h.snapshot->'transactions') t where h.id=$1 and t->>'externalID'=$2",[h,'wallet:'+result.id])).rows[0].amount;
      assert.equal(stored,'-'+expected,input);
    }
  });
  await check('recognized amount currency is inferred while symbol-free amounts stay pending',async()=>{
    const inferred=await capture(anon,phone2.token,uuid(),'$31.54','');
    assert.equal(inferred.state,'recorded');
    assert.equal(inferred.currency,'USD'); assert.equal(inferred.currency_inferred,true);
    const unknown=await capture(anon,phone2.token,uuid(),'31.54','');
    assert.equal(unknown.state,'pending'); assert.equal(unknown.reason,'Не получена валюта покупки');
    const explicitForeign=await capture(anon,phone2.token,uuid(),'$31.54','EUR');
    assert.equal(explicitForeign.state,'pending');
    assert.equal(explicitForeign.reason,'Валюта покупки отличается от валюты счета');
    await rpc(owner,'mora_resolve_capture',[h,unknown.id,accountID,'','',true]);
    await rpc(owner,'mora_resolve_capture',[h,explicitForeign.id,accountID,'','',true]);
  });
  await check('malformed, nonpositive, excessive and duplicate-symbol amounts stay pending',async()=>{
    const before=(await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length;
    for (const input of ['', '$0.00', '-31.54', '$31.54 USD', '$31.54junk', '31$54', '12,34.56', '1000000000000', '0.0000001']) {
      const result=await capture(anon,phone2.token,uuid(),input,'USD');
      assert.equal(result.state,'pending',input);
      assert.equal(result.reason,'Не получена положительная сумма',input);
      await rpc(owner,'mora_resolve_capture',[h,result.id,accountID,'','',true]);
    }
    assert.equal((await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length,before);
  });
  await check('the parser stays private and capture RPC remains available to phone tokens',async()=>{
    await denied(()=>rpc(anon,'mora_parse_payment_amount',['$31.54']));
    await denied(()=>rpc(owner,'mora_parse_payment_amount',['$31.54']));
    await denied(()=>rpc(anon,'mora_parse_payment_currency',['$31.54']));
    await denied(()=>rpc(owner,'mora_parse_payment_currency',['$31.54']));
    await denied(()=>capture(anon,'0'.repeat(64),uuid(),'$31.54'));
  });
  const eurAccount=uuid().toUpperCase();
  const accountJSON={id:eurAccount,name:'EUR review account',currency:'EUR',kind:'checking',openingBalance:0,color:'green',archived:false,conversionFeePercent:0.23};
  const latestForReview=await rpc(owner,'mora_get_household',[h]);
  const withAccount=(await admin.query("select jsonb_set(snapshot,'{accounts}',(snapshot->'accounts') || $2::jsonb)::text value from public.mora_households where id=$1",[h,JSON.stringify([accountJSON])])).rows[0].value;
  assert.equal(await rpc(owner,'mora_save_household',[h,latestForReview.version,withAccount]),true);
  const eurPhone=await rpc(owner,'mora_create_phone_token',[h,eurAccount,'Wallet EUR']);
  await check('formatted dollar amount is accepted for automatic USD to EUR conversion',async()=>{
    const merchant='Uniqlo USA LLC UNIQLO_US-';
    const received=await capture(anon,eurPhone.token,uuid(),'$14.90','',merchant);
    assert.equal(received.state,'pending');
    assert.equal(received.currency,'USD'); assert.equal(received.currency_inferred,true);
    assert.equal(received.reason,null); assert.equal(received.next_step,'mora_conversion');
    const pending=(await rpc(owner,'mora_list_pending',[h])).find(item=>item.id===received.id);
    assert.equal(pending.currency,'USD');
    assert.equal(pending.reason,'Валюта покупки отличается от валюты счета');
    const transaction={id:uuid(),date,merchant,amount:-13.44,accountID:eurAccount,kind:'expense',categoryID,
      note:'Apple Wallet',tags:['Apple Wallet'],conversion:{originalAmount:-14.90,originalCurrency:'USD',accountCurrency:'EUR',
        rate:0.9,date:'2026-10-16T00:00:00Z',provider:'Visa',bankFeePercent:0.23}};
    const booked=await rpc(member,'mora_review_capture',[h,received.id,transaction]);
    assert(booked.snapshot.transactions.some(item=>item.id===received.id.toUpperCase() && item.externalID==='wallet:'+received.id));
    const stored=(await admin.query('select currency,state from public.mora_captures where id=$1',[received.id])).rows[0];
    assert.equal(stored.currency,'USD'); assert.equal(stored.state,'recorded');
  });
  const reviewedCapture=await capture(anon,eurPhone.token,uuid(),'$31.54','');
  const reviewedTransaction={id:uuid(),date:'2026-10-16T20:19:00Z',merchant:'Cafe · Apple Wallet · Test phone · 20:19',amount:-28.45,
    accountID:eurAccount,kind:'expense',categoryID,note:'Edited review note',tags:['Apple Wallet','reviewed'],externalID:'must-be-replaced',
    conversion:{originalAmount:-31.54,originalCurrency:'USD',accountCurrency:'EUR',rate:0.9,date:'2026-10-16T00:00:00Z',provider:'Visa',bankFeePercent:0.23}};
  await check('review saves currency conversion and every edited transaction field atomically',async()=>{
    const result=await rpc(member,'mora_review_capture',[h,reviewedCapture.id,reviewedTransaction]);
    const tx=result.snapshot.transactions.find(t=>t.externalID==='wallet:'+reviewedCapture.id);
    assert.deepEqual(tx,{...reviewedTransaction,id:reviewedCapture.id.toUpperCase(),externalID:'wallet:'+reviewedCapture.id});
    assert.equal((await rpc(owner,'mora_list_pending',[h])).some(c=>c.id===reviewedCapture.id),false);
    const state=(await admin.query('select state,transaction_id from public.mora_captures where id=$1',[reviewedCapture.id])).rows[0];
    assert.equal(state.state,'recorded'); assert.equal(state.transaction_id,reviewedCapture.id);
  });
  await check('a retry preserves the first review and never duplicates or overwrites it',async()=>{
    const before=await rpc(owner,'mora_get_household',[h]);
    const retry=await rpc(owner,'mora_review_capture',[h,reviewedCapture.id,{...reviewedTransaction,merchant:'Retry must not overwrite'}]);
    assert.equal(retry.version,before.version);
    assert.deepEqual(retry.snapshot,before.snapshot);
  });
  await check('review rejects non-members, phone tokens, invalid accounts and inconsistent conversions',async()=>{
    const pending=await capture(anon,eurPhone.token,uuid(),'$31.54','');
    await denied(()=>rpc(outsider,'mora_review_capture',[h,pending.id,reviewedTransaction]));
    await denied(()=>rpc(anon,'mora_review_capture',[h,pending.id,reviewedTransaction]));
    const before=await rpc(owner,'mora_get_household',[h]);
    for(const invalid of [{...reviewedTransaction,accountID:uuid()},{...reviewedTransaction,amount:0},
      {...reviewedTransaction,conversion:{...reviewedTransaction.conversion,rate:1}},
      {...reviewedTransaction,importBatchID:uuid()}]) {
      await assert.rejects(()=>rpc(owner,'mora_review_capture',[h,pending.id,invalid]));
    }
    assert.equal((await rpc(owner,'mora_get_household',[h])).version,before.version);
    assert.equal((await rpc(owner,'mora_list_pending',[h])).some(c=>c.id===pending.id),true);
    await rpc(owner,'mora_resolve_capture',[h,pending.id,accountID,'','',true]);
    await assert.rejects(()=>rpc(owner,'mora_review_capture',[h,pending.id,reviewedTransaction]));
  });
  await check('two reviewers produce one transaction and full-form transfers also work',async()=>{
    const pending=await capture(anon,phone2.token,uuid(),'','');
    const transfer={id:uuid(),date,merchant:'Wallet transfer review',amount:-10,accountID,kind:'transfer',
      note:'Transfer from full form',tags:['Apple Wallet'],destinationAccountID:eurAccount,destinationAmount:9};
    const before=await rpc(owner,'mora_get_household',[h]);
    const results=await Promise.all([rpc(owner,'mora_review_capture',[h,pending.id,transfer]),rpc(member,'mora_review_capture',[h,pending.id,transfer])]);
    assert(results.every(r=>r.version===before.version+1));
    assert.equal(results[0].snapshot.transactions.filter(t=>t.externalID==='wallet:'+pending.id).length,1);
    assert.equal(results[0].snapshot.transactions.find(t=>t.externalID==='wallet:'+pending.id).destinationAmount,9);
  });
  await check('Wallet import collection is member-only, groups all phones and dates, and serializes concurrent Macs',async()=>{
    await denied(()=>rpc(outsider,'mora_collect_wallet_import',[h]));
    await denied(()=>rpc(anon,'mora_collect_wallet_import',[h]));
    const before=await rpc(owner,'mora_get_household',[h]);
    const expected=before.snapshot.transactions.filter(t=>t.externalID?.startsWith('wallet:'));
    assert(expected.length>2);
    const results=await Promise.all([rpc(owner,'mora_collect_wallet_import',[h]),rpc(member,'mora_collect_wallet_import',[h])]);
    assert.equal(results.filter(r=>r.batch_id).length,1);
    const after=await rpc(owner,'mora_get_household',[h]);
    assert.equal(after.version,before.version+1);
    assert.equal(after.snapshot.imports.length,1);
    const batch=after.snapshot.imports[0];
    assert.equal(batch.source,'Apple Shortcuts');
    assert.equal(batch.totalRows,expected.length);
    assert.equal(batch.transactions.length,expected.length);
    assert.equal(new Set(batch.transactions.map(t=>t.id)).size,expected.length);
    assert(after.snapshot.transactions.every(t=>t.importBatchID===batch.id));
    assert.equal(batch.accountNames[accountID],'Shared test account');
    const retry=await rpc(owner,'mora_collect_wallet_import',[h]);
    assert.equal(retry.batch_id,null);
    assert.deepEqual(retry.envelope,after);
  });
  await check('later Wallet arrivals form a new import and cannot reattach an already recorded purchase',async()=>{
    const before=await rpc(owner,'mora_get_household',[h]);
    const payment=await capture(anon,phone2.token,uuid(),'2','USD','New sync purchase');
    assert.equal(payment.state,'recorded');
    const result=await rpc(owner,'mora_collect_wallet_import',[h]);
    assert(result.batch_id);
    assert.equal(result.envelope.snapshot.imports.length,before.snapshot.imports.length+1);
    const batch=result.envelope.snapshot.imports.at(-1);
    assert.equal(batch.transactions.length,1);
    assert.equal(batch.transactions[0].externalID,'wallet:'+payment.id);
    // Legacy writers may omit the provenance field: the saved batch still prevents duplicates.
    const snapshot=result.envelope.snapshot;
    delete snapshot.transactions[0].importBatchID;
    assert.equal(await rpc(owner,'mora_save_household',[h,result.envelope.version,snapshot]),true);
    const retry=await rpc(owner,'mora_collect_wallet_import',[h]);
    assert.equal(retry.batch_id,null);
    assert.equal(retry.envelope.snapshot.imports.length,2);
  });
  const cardCapture=(token,amount,merchant,card,id=uuid())=>rpc(anon,'mora_capture_payment',[token,id,amount,'',merchant,date,card]);
  const cardsOf=async(client=owner)=>Object.fromEntries((await rpc(client,'mora_list_wallet_cards',[h])).map(c=>[c.card,c]));
  await check('a new Wallet card holds its purchases until a member links it in Mora',async()=>{
    const before=(await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length;
    const first=await cardCapture(phone2.token,'$4.25','Card coffee','Travel  Visa');
    assert.equal(first.state,'pending'); assert.equal(first.next_step,'mora_link_card'); assert.equal(first.card_linked,false);
    const noAmount=await cardCapture(phone2.token,'','Card transit','travel visa');
    const pending=(await rpc(owner,'mora_list_pending',[h])).filter(c=>c.card==='Travel Visa');
    assert.equal(pending.length,2); assert(pending.every(c=>c.card_linked===false && c.reason==='Новая карта: выберите для неё счёт'));
    const card=(await cardsOf(member))['Travel Visa'];
    assert.equal(card.account_id,null); assert.equal(card.default_account_id,accountID.toLowerCase()); assert.equal(card.pending_count,2);
    assert.equal((await rpc(owner,'mora_get_household',[h])).snapshot.transactions.length,before);
    await denied(()=>rpc(anon,'mora_list_wallet_cards',[h]));
    await denied(()=>rpc(outsider,'mora_list_wallet_cards',[h]));
    await denied(()=>rpc(anon,'mora_link_wallet_card',[h,card.id,eurAccount]));
    await denied(()=>rpc(outsider,'mora_link_wallet_card',[h,card.id,eurAccount]));
    await assert.rejects(()=>rpc(owner,'mora_link_wallet_card',[h,card.id,uuid()]));
    assert.equal(await rpc(owner,'mora_link_wallet_card',[h,card.id,eurAccount]),2);
    const moved=(await rpc(owner,'mora_list_pending',[h])).filter(c=>c.card==='Travel Visa');
    assert(moved.every(c=>c.account_id===eurAccount.toLowerCase() && c.card_linked===true));
    assert.equal(moved.find(c=>c.id===first.id).reason,'Валюта покупки отличается от валюты счета');
    assert.equal(moved.find(c=>c.id===noAmount.id).reason,'Не получена положительная сумма');
    const next=await cardCapture(phone2.token,'€3,10','Card bakery','TRAVEL VISA');
    assert.equal(next.state,'recorded'); assert.equal(next.card_linked,true);
    const tx=(await rpc(owner,'mora_get_household',[h])).snapshot.transactions.find(t=>t.externalID==='wallet:'+next.id);
    assert.equal(tx.accountID,eurAccount);
    for (const id of [first.id,noAmount.id]) await rpc(owner,'mora_resolve_capture',[h,id,accountID,'','',true]);
  });
  await check('first card review validates, links and books atomically without changing a committed retry',async()=>{
    const payment=await cardCapture(phone2.token,'','Review shop','Review Visa');
    const waiting=await cardCapture(phone2.token,'$8.00','Second purchase','Review Visa');
    const card=(await cardsOf())['Review Visa'];
    const reviewed={id:uuid(),date,merchant:'Confirmed amount',amount:-7.4,accountID,kind:'expense',note:'Reviewed',tags:['Apple Wallet']};
    await assert.rejects(()=>rpc(owner,'mora_review_capture',[h,payment.id,{...reviewed,amount:0}]));
    assert.equal((await cardsOf())['Review Visa'].account_id,null);
    const result=await rpc(owner,'mora_review_capture',[h,payment.id,reviewed]);
    const recorded=result.snapshot.transactions.find(t=>t.externalID==='wallet:'+payment.id);
    assert.equal(recorded.amount,-7.4); assert.equal(recorded.merchant,'Confirmed amount');
    assert.equal((await cardsOf())['Review Visa'].account_id,accountID.toLowerCase());
    const pending=(await rpc(owner,'mora_list_pending',[h])).find(c=>c.id===waiting.id);
    assert.equal(pending.card_linked,true); assert.equal(pending.reason,null);
    const retry=await rpc(owner,'mora_review_capture',[h,payment.id,{...reviewed,accountID:eurAccount,amount:-100}]);
    assert.deepEqual(retry,result);
    assert.equal((await cardsOf())['Review Visa'].account_id,accountID.toLowerCase());
  });
  await check('purchases without a card keep the phone key account and old senders keep working',async()=>{
    const withoutCard=await cardCapture(phone2.token,'$1.00','No card text','');
    const legacy=await capture(anon,phone2.token,uuid(),'1.00','USD','Legacy sender');
    assert.equal(withoutCard.state,'recorded'); assert.equal(withoutCard.card,null); assert.equal(legacy.state,'recorded');
  });
  assert(saved.includes('-123456789012.123456'));
  await fs.mkdir(path.join(here,'fixtures'),{recursive:true});
  await fs.writeFile(path.join(here,'fixtures/backend-ledger.json'),saved+'\n');
  console.log(`${checks} PostgreSQL integration checks passed. Backend snapshot exported for Swift compatibility tests.`);
} finally {
  await Promise.allSettled(clients.map(client=>client.end()));
  if(server && server.exitCode===null) { const exited=once(server,'exit'); server.kill('SIGTERM'); await exited; }
  await fs.rm(runtime,{recursive:true,force:true});
}
