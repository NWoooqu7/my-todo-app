// ローカルPostgreSQL互換環境でSQL/RLSを検証。本番には接続しません。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
(async () => {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    grant usage on schema auth, public to authenticated, anon;
    grant execute on function auth.uid() to authenticated, anon;
    insert into auth.users values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
                                  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    create table public.todos(id integer, title text);
    insert into public.todos values(1, '既存のTodo');
  `);
  const sql = fs.readFileSync('supabase-typing.sql','utf8');
  await db.exec(sql);
  await db.exec(sql); // 再実行しても問題が増えない
  assert.equal((await db.query('select count(*)::int n from public.exercises')).rows[0].n,20);
  assert.deepEqual((await db.query('select level,count(*)::int n from public.exercises group by level order by level')).rows.map(r=>r.n),[5,5,5,5]);
  assert.equal((await db.query('select title from public.todos')).rows[0].title,'既存のTodo');
  const exercises = (await db.query('select * from public.exercises order by display_order')).rows;
  fs.writeFileSync('work/exercises-fixture.json', JSON.stringify(exercises));
  const userA='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', userB='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const ex=exercises[0];
  async function asUser(user, action, role='authenticated') {
    await db.exec('begin');
    try {
      await db.exec('set local role ' + role);
      await db.query("select set_config('request.jwt.claim.sub', $1, true)",[user || '']);
      const result=await action(); await db.exec('commit'); return result;
    } catch(e) { await db.exec('rollback'); throw e; }
  }
  const args=id=>[id,ex.id,ex.expected_input,10000,true,'2026-09-09T10:00:00Z','2026-09-09T10:00:10Z'];
  const rpc=values=>db.query('select public.record_typing_attempt($1,$2,$3,$4,$5,$6,$7) result',values).then(r=>r.rows[0].result);
  const ids=['20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000003'];
  let r=await asUser(userA,()=>rpc(args(ids[0])));
  assert.equal(r.progress.attempt_count,1); assert.equal(r.progress.status,'practicing');
  const duplicate=await asUser(userA,()=>rpc(args(ids[0])));
  assert.equal(duplicate.progress.attempt_count,1);
  for (const id of ids.slice(1)) r=await asUser(userA,()=>rpc(args(id)));
  assert.equal(r.progress.status,'mastered'); assert.equal(r.progress.qualifying_attempt_count,3);
  const bad=args('20000000-0000-4000-8000-000000000004');bad[2]='x';
  r=await asUser(userA,()=>rpc(bad));
  assert.equal(r.progress.status,'mastered'); assert.equal(r.progress.qualifying_attempt_count,3);
  assert.equal(r.progress.attempt_count,4);
  const changed=args(ids[0]);changed[2]='different';
  await assert.rejects(()=>asUser(userA,()=>rpc(changed)),/別の結果/);
  const zero=args('20000000-0000-4000-8000-000000000005');zero[3]=0;
  await assert.rejects(()=>asUser(userA,()=>rpc(zero)),/不正/);
  const empty=args('20000000-0000-4000-8000-000000000005');empty[2]='';
  await assert.rejects(()=>asUser(userA,()=>rpc(empty)),/不正/);
  for (const table of ['typing_attempts','user_exercise_progress']) {
    assert.equal((await asUser(userB,()=>db.query('select * from public.'+table))).rows.length,0);
    await assert.rejects(()=>asUser(userB,()=>db.query('delete from public.'+table)));
    await assert.rejects(()=>asUser(userB,()=>db.query('update public.'+table+' set user_id=$1',[userB])));
  }
  await assert.rejects(()=>asUser(userA,()=>db.query('update public.exercises set title=\'変更\'')));
  await assert.rejects(()=>asUser(userA,()=>db.query('insert into public.user_exercise_progress(user_id,exercise_id,status) values($1,$2,\'mastered\')',[userB,ex.id])));
  await assert.rejects(()=>asUser(null,()=>rpc(args(ids[0]))),/ログイン/);
  await assert.rejects(()=>asUser(null,()=>rpc(args(ids[0])),'anon'));
  await assert.rejects(()=>asUser(null,()=>db.query('select * from public.exercises'),'anon'));
  await db.query('update public.exercises set is_published=false where id=$1',[exercises[19].id]);
  assert.equal((await asUser(userA,()=>db.query('select * from public.exercises'))).rows.length,19);
  const unpublished=args('20000000-0000-4000-8000-000000000006');unpublished[1]=exercises[19].id;
  await assert.rejects(()=>asUser(userA,()=>rpc(unpublished)),/公開中/);
  // 関数の途中で失敗させ、結果INSERTもロールバックされることを確認。
  await db.exec(`
    create function public.test_fail_progress() returns trigger language plpgsql as
    $$ begin raise exception 'forced rollback'; end $$;
    create trigger test_failure before insert or update on public.user_exercise_progress
    for each row execute function public.test_fail_progress();
  `);
  await assert.rejects(()=>asUser(userA,()=>rpc(args('20000000-0000-4000-8000-000000000007'))),/forced rollback/);
  assert.equal((await db.query('select count(*)::int n from public.typing_attempts')).rows[0].n,4);
  await db.exec('drop trigger test_failure on public.user_exercise_progress');
  // JSとSQLが同じUnicode文字単位、同じ式で採点するか確認。
  const script=fs.readFileSync('outputs/index.html','utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
  const scoring=script.slice(script.indexOf('function normalizeText'),script.indexOf('function message'));
  const context={};vm.createContext(context);vm.runInContext(scoring,context);
  const cases=[['abc','abc'],['abc','ac'],['abc','axbc'],['abc','axc'],['か\u3099','が'],['a\r\nb','a\nb'],['😀あ','😀い'],['a b','ab'],['ABC','ＡＢＣ']];
  for(const [expected,typed] of cases){
    const js=context.calculateScore(expected,typed,60000);
    const row=(await db.query('select public.typing_edit_distance(public.typing_normalize($1),public.typing_normalize($2)) n',[expected,typed])).rows[0];
    assert.equal(js.error_count,row.n);
  }
  assert.equal(context.calculateScore('abc','abc',60000).accuracy,100);
  assert.equal(context.calculateScore('abc','ac',60000).typing_speed,2);
  assert.throws(()=>context.calculateScore('abc','',1000));
  assert.throws(()=>context.calculateScore('abc','abc',0));
  // Bにも同一IDを使えるが、所有者ごとに分離される。
  r=await asUser(userB,()=>rpc(args(ids[0])));
  assert.equal(r.progress.attempt_count,1);assert.equal(r.attempt.user_id,userB);
  assert.equal((await asUser(userB,()=>db.query('select * from public.typing_attempts'))).rows.length,1);
  await db.close();
  console.log('PASS: 20 seeds, migration rerun, existing Todo preservation, scoring/Unicode, mastery, idempotency, invalid input, atomic rollback, two-user RLS, unpublished/anonymous/write denial.');
})().catch(error=>{console.error(error);process.exitCode=1;});
