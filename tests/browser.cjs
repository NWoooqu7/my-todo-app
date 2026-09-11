// UI操作の回帰テスト。Supabase接続だけをテスト用応答に置き換えます。
const assert=require('node:assert/strict');
const fs=require('node:fs');
const http=require('node:http');
const { chromium }=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const exercises=JSON.parse(fs.readFileSync('work/exercises-fixture.json','utf8'));
const html=fs.readFileSync('outputs/index.html','utf8');
const mock = `
window.testBackend = {
  session:null, callback:null, failLoad:false, failSave:true, rpcCalls:0, attempts:new Map(), progress:new Map(),
  event(event,session){this.session=session;this.callback(event,session)}
};
window.supabase={createClient(){
  const b=window.testBackend;
  const session=email=>({user:{id:email.startsWith('other')?'user-b':'user-a',email}});
  return {
    auth:{
      onAuthStateChange(cb){b.callback=cb;return {data:{subscription:{unsubscribe(){}}}}},
      async getSession(){return {data:{session:b.session},error:null}},
      async signInWithPassword({email}){const s=session(email);b.event('SIGNED_IN',s);return {data:{session:s},error:null}},
      async signUp(){return {data:{session:null},error:null}},
      async resetPasswordForEmail(email,{redirectTo}){b.redirect=redirectTo;return {data:{},error:null}},
      async updateUser(){return {data:{},error:null}},
      async signOut(){b.event('SIGNED_OUT',null);return {error:null}}
    },
    from(table){
      return {select(){return this},eq(){return this},order(){return this},limit(){return this},
        then(resolve,reject){
          return Promise.resolve().then(()=>{
            if(b.failLoad)return {error:{message:'test load failure'}};
            return {data:table==='exercises'?window.testExercises:
              table==='typing_attempts'?[...b.attempts.values()].map(r=>r.attempt).filter(a=>a.user_id===b.session.user.id):[...b.progress.values()].filter(p=>p.user_id===b.session.user.id),error:null};
          }).then(resolve,reject)
        }}
    },
    async rpc(name,args){
      b.rpcCalls++;await new Promise(r=>setTimeout(r,80));
      let result=b.attempts.get(args.p_attempt_id);
      if(!result){
        const exercise=window.testExercises.find(e=>e.id===args.p_exercise_id);
        const score=calculateScore(exercise.expected_input,args.p_typed_text,args.p_elapsed_ms);
        const key=b.session.user.id+exercise.id;
        const prior=b.progress.get(key);
        const count=(prior?.attempt_count||0)+1;
        const qualified=(prior?.qualifying_attempt_count||0)+(score.accuracy>=95&&score.typing_speed>=exercise.target_speed?1:0);
        const progress={user_id:b.session.user.id,exercise_id:exercise.id,attempt_count:count,
          qualifying_attempt_count:qualified,status:qualified>=3?'mastered':'practicing',
          best_accuracy:Math.max(prior?.best_accuracy||0,score.accuracy),
          best_speed:Math.max(prior?.best_speed||0,score.typing_speed),last_practiced_at:args.p_completed_at};
        if(args.p_measurement?.source!=='test') b.progress.set(key,progress);
        result={attempt:{...score,id:args.p_attempt_id,user_id:b.session.user.id,exercise_id:exercise.id,measurement:args.p_measurement,expected_snapshot:args.p_expected_input,hint_used:args.p_hint_used,completed_at:args.p_completed_at,elapsed_ms:args.p_elapsed_ms},progress:args.p_measurement?.source==='test'?(prior||null):progress};
        b.attempts.set(args.p_attempt_id,result);
      }
      if(b.failSave){b.failSave=false;throw Error('test response lost after commit')}
      return {data:result,error:null};
    }
  };
}};
`;
(async()=>{
  const server=http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(html)});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({executablePath:process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
    const page=await browser.newPage({viewport:{width:1280,height:1000}});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    await page.route('https://cdn.jsdelivr.net/**',route=>route.fulfill({contentType:'text/javascript',body:'window.testExercises='+JSON.stringify(exercises)+';'+mock}));
    await page.goto('http://127.0.0.1:'+server.address().port);
    await page.locator('#auth-section').waitFor({state:'visible'});
    await page.click('#guest-button'); await page.click('#start-button');
    await page.locator('#typing-input').pressSequentially('fjfjfjfj');
    await page.locator('#typing-input').press('Enter');
    assert.equal(await page.locator('#typing-input').inputValue(),'fjfjfjfj');
    await page.click('#score-button');
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),0);
    assert.match(await page.locator('#save-message').textContent(),/お試し完了/);
    await page.fill('#email-input','learner@example.test');
    await page.fill('#password-input','test-password-only');
    await page.click('#signup-button');
    await page.getByText('確認メールを送りました。メール内のリンクを開いてからログインしてください。',{exact:true}).waitFor();
    await page.click('#forgot-password-button');
    await page.getByText('再設定メールを送りました。メール内のリンクを開いてください。',{exact:true}).waitFor();
    await page.evaluate(()=>window.testBackend.failLoad=true);
    await page.fill('#password-input','test-password-only');
    await page.click('#login-button');
    await page.locator('#reload-button').waitFor({state:'visible'});
    await page.evaluate(()=>window.testBackend.failLoad=false);
    await page.click('#reload-button');
    await page.waitForFunction(()=>document.querySelectorAll('.exercise').length===40);
    await page.locator('#trial-offer').waitFor({state:'visible'});
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),0);
    await page.click('#discard-trial');
    await page.locator('.exercise').first().click();
    assert.equal(await page.locator('#hint-toggle').isChecked(),true);
    assert.equal(await page.locator('.key.active').textContent(),'f');
    await page.screenshot({path:'work/typing-keyboard.png',fullPage:true});
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.setViewportSize({width:1280,height:1000});
    await page.click('#start-button');
    await page.click('#score-button'); // 空入力は練習を継続、保存しない
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),0);
    await page.locator('#typing-input').pressSequentially('x');
    await page.locator('#typing-input').press('Backspace');
    await page.locator('#typing-input').pressSequentially(exercises[0].expected_input);
    await page.click('#score-button');
    await page.locator('#save-button').waitFor({state:'visible'});
    assert.equal(await page.locator('#typing-input').inputValue(),exercises[0].expected_input);
    assert.equal(await page.locator('#again-button').isDisabled(),true);
    assert.equal(await page.locator('.exercise').first().isDisabled(),true);
    await page.click('#save-button');
    await page.waitForFunction(()=>document.getElementById('save-message').textContent.startsWith('保存しました'));
    assert.equal(await page.evaluate(()=>window.testBackend.attempts.size),1);
    assert.equal(await page.evaluate(()=>[...window.testBackend.progress.values()][0].attempt_count),1);
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),2);
    assert.match(await page.locator('#measurement-detail').textContent(),/修正操作 1回/);
    // 残り2回を練習して習得済み。二重クリックでも1回のみ保存。
    for(let i=0;i<2;i++){
      await page.click('#again-button');await page.click('#start-button');
      await page.fill('#typing-input',exercises[0].expected_input);
      await page.evaluate(()=>{document.getElementById('score-button').click();document.getElementById('score-button').click()});
      await page.waitForFunction(()=>document.getElementById('save-message').textContent.startsWith('保存しました'));
    }
    assert.equal(await page.evaluate(()=>[...window.testBackend.progress.values()][0].status),'mastered');
    assert.equal(await page.evaluate(()=>window.testBackend.attempts.size),3);
    await page.click('#next-button');
    assert.equal(await page.locator('#exercise-title').textContent(),exercises[1].title);
    // 中断・やり直しは保存しない。
    page.on('dialog',dialog=>dialog.accept());
    const countBefore=await page.evaluate(()=>window.testBackend.rpcCalls);
    await page.click('#start-button');
    await page.locator('#typing-input').pressSequentially('as');
    await page.click('#restart-button');
    assert.equal(await page.locator('#typing-input').inputValue(),'');
    await page.click('#stop-button');
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),countBefore);
    await page.locator('.exercise-group[data-level="3"] summary').click();
    await page.locator('.exercise').nth(10).click();
    assert.equal(await page.locator('#keyboard-area').isHidden(),true);
    await page.check('#hint-toggle');
    assert.equal(await page.locator('#keyboard-area').isVisible(),true);
    // 日本語IME: composition中は文字比較も採点もしない。Enter単体では終了しない。
    await page.locator('.exercise-group[data-level="8"] summary').click();
    await page.locator('.exercise').nth(35).click();
    await page.click('#start-button');
    const before=await page.evaluate(()=>window.testBackend.rpcCalls);
    await page.locator('#typing-input').dispatchEvent('compositionstart');
    await page.fill('#typing-input',exercises[35].expected_input);
    assert.equal(await page.locator('#score-button').isDisabled(),true);
    assert.equal(await page.locator('#target .correct').count(),0);
    await page.locator('#typing-input').press('Enter');
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),before);
    await page.locator('#typing-input').dispatchEvent('compositionend');
    await page.fill('#typing-input',exercises[35].expected_input);
    await page.click('#score-button');
    await page.waitForFunction(()=>document.getElementById('save-message').textContent.startsWith('保存しました'));
    await page.screenshot({path:'work/typing-desktop.png',fullPage:true});
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.screenshot({path:'work/typing-mobile.png',fullPage:true});
    // 同じページでログアウト・別ユーザーに切替え、以前の進捗が消えること。
    await page.click('#logout-button');
    await page.locator('#auth-section').waitFor({state:'visible'});
    assert.equal(await page.locator('#typing-input').inputValue(),'');
    await page.fill('#email-input','other@example.test');await page.fill('#password-input','test-password-only');
    await page.click('#login-button');
    await page.waitForFunction(()=>document.querySelectorAll('.exercise').length===40);
    assert.match(await page.locator('#summary').textContent(),/練習 0回/);
    // リカバリイベント経由のパスワード再設定とサインアウト。
    await page.evaluate(()=>window.testBackend.event('PASSWORD_RECOVERY',window.testBackend.session));
    await page.locator('#password-reset-section').waitFor({state:'visible'});
    await page.fill('#new-password-input','replacement-only');await page.fill('#confirm-password-input','not-matching');
    await page.click('#update-password-button');
    assert.match(await page.locator('#password-reset-message').textContent(),/一致しません/);
    await page.fill('#confirm-password-input','replacement-only');
    await page.click('#update-password-button');
    await page.locator('#auth-section').waitFor({state:'visible'});
    assert.match(await page.locator('#auth-message').textContent(),/変更しました/);
    // 体験結果をログイン後に明示的に保存。
    await page.click('#guest-button'); await page.click('#start-button');
    await page.locator('#typing-input').pressSequentially('fjfjfjfj');
    await page.click('#score-button'); await page.click('#guest-login');
    const beforeImport=await page.evaluate(()=>window.testBackend.rpcCalls);
    await page.fill('#email-input','learner@example.test');await page.fill('#password-input','test-password-only');
    await page.click('#login-button');
    await page.waitForFunction(()=>document.querySelectorAll('.exercise').length===40);
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),beforeImport);
    await page.click('#import-trial');
    await page.waitForFunction(()=>document.getElementById('save-message').textContent.startsWith('保存しました'));
    assert.equal(await page.evaluate(()=>window.testBackend.rpcCalls),beforeImport+1);
    assert.match(await page.locator('#growth').textContent(),/まだありません/);
    // 動作確認用は既存進捗に加算しない。
    const oldCount=await page.evaluate(()=>[...window.testBackend.progress.values()].find(p=>p.user_id==='user-a').attempt_count);
    await page.click('#again-button');await page.check('#test-mode');await page.click('#start-button');
    await page.locator('#typing-input').pressSequentially('fjfjfjfj');await page.click('#score-button');
    await page.waitForFunction(()=>document.getElementById('save-message').textContent.includes('動作確認用'));
    assert.equal(await page.evaluate(()=>[...window.testBackend.progress.values()].find(p=>p.user_id==='user-a').attempt_count),oldCount);
    assert.equal(await page.evaluate(()=>eligible({measurement:{version:1,source:'test',method:'direct'}})),false);
    assert.equal(await page.evaluate(()=>eligible({measurement:null})),false);
    assert.equal(await page.evaluate(()=>eligible({measurement:{version:1,source:'practice',method:'assisted'}})),false);
    // 同じ条件だけ比較。古いテスト履歴から成長を推定しない。
    const comparison=await page.evaluate(()=>{
      const record={id:'new',exercise_id:selected.id,expected_snapshot:selected.expected_input,hint_used:true,
        accuracy:100,typing_speed:20,completed_at:new Date().toISOString(),
        measurement:{version:1,source:'practice',method:'direct',corrections:1,keys:{}}};
      history=[{...record,id:'old',accuracy:90,measurement:{...record.measurement,corrections:3}}];
      showGrowth(record);const same=document.getElementById('growth').textContent;
      history[0].hint_used=false;showGrowth(record);
      return {same,different:document.getElementById('growth').textContent};
    });
    assert.match(comparison.same,/修正操作 -2回/);
    assert.match(comparison.different,/まだありません/);
    assert.deepEqual(errors,[]);
    const offline=await browser.newPage();
    await offline.route('https://cdn.jsdelivr.net/**',route=>route.abort());
    await offline.goto('http://127.0.0.1:'+server.address().port);
    await offline.waitForFunction(()=>document.getElementById('boot-message').textContent.includes('インターネット接続'));
    await offline.close();
    console.log('PASS: 40 exercises, auth, guest opt-in save, cancel/restart, English Enter, correction metrics, comparable growth only, test isolation, retry, IME, private-state clearing, responsive layout.');
  } finally { if(browser)await browser.close();await new Promise(r=>server.close(r)); }
})().catch(e=>{console.error(e);process.exitCode=1;});
