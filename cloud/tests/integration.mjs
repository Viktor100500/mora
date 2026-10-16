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
  const saved=(await admin.query('select snapshot::text as value from public.mora_households where id=$1',[h])).rows[0].value;
  assert(saved.includes('-123456789012.123456'));
  await fs.mkdir(path.join(here,'fixtures'),{recursive:true});
  await fs.writeFile(path.join(here,'fixtures/backend-ledger.json'),saved+'\n');
  console.log(`${checks} PostgreSQL integration checks passed. Backend snapshot exported for Swift compatibility tests.`);
} finally {
  await Promise.allSettled(clients.map(client=>client.end()));
  if(server && server.exitCode===null) { const exited=once(server,'exit'); server.kill('SIGTERM'); await exited; }
  await fs.rm(runtime,{recursive:true,force:true});
}
