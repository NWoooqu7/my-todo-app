# ことことタイピング

PCキーボードの初心者が、キーの位置・ホームポジション・単語・日本語短文を繰り返し練習するアプリです。
HTML/CSS/JavaScriptは `outputs/index.html` の1ファイル。ビルド不要で、Supabase Authとデータベースを利用します。

## できること

- オリジナル問題20問（4段階×5問）の選択・入力・採点・再練習
- JISキーボードの主要キー配置、ホームポジション、キー練習の次のキー表示
- キーボード表示の切り替え（最初の2段階は初期表示、後半は初期非表示）
- 日本語IME確定後の採点。変換中やEnterキーだけでは終了しません
- 正確率・入力速度・時間・誤り数の表示
- 正確率95%以上かつ問題の目標速度以上を合計3回達成すると習得済み
- 個人の進捗と結果をクラウド保存。同じアカウントで別のPCから継続
- 登録・ログイン・ログアウト・メールによるパスワード再設定
- 保存に失敗した結果の再送と二重送信防止

漫画・アニメの既存の名言は今回収録していません。利用条件を確認できた文章について、作品名・キャラクター名を表示できる欄を用意しています。
聞き取り・議事録練習、かな入力、US配列、ランキング、履歴リセットは今後の対象です。

## 導入：SQLを先に適用してからアプリを公開

1. Supabase Dashboardで、このアプリのProject URLに対応するプロジェクトを開きます。
2. SQL Editor → New queryを開き、`supabase-typing.sql` の**全体**を貼り付けてRunを実行します。
3. エラーがないことを確認します。Table Editorに `exercises`、`typing_attempts`、
   `user_exercise_progress` が作られ、`exercises` に20問入ります。
4. `outputs/index.html` 冒頭のJavaScriptにある `SUPABASE_URL` と
   `SUPABASE_PUBLISHABLE_KEY` が同じプロジェクトの公開用設定か確認します。
5. Authentication → URL Configurationで公開URLをSite URL・Redirect URLsに設定します。
   このプロジェクトの公開先は以下です。

   https://nwoooqu7.github.io/my-todo-app/outputs/index.html

6. SQL適用後にHTMLをGitHubへpushし、PRでmainへmergeします。Pagesの公開元が
   main / rootの場合、Actionsのデプロイ成功後に上記URLで新しい画面を確認します。

SQLはトランザクション内で適用します。失敗時は変更が取り消されます。
同じ構成に再実行しても初期問題は重複せず、編集済み問題も上書きしません。
すでに同名テーブルが別構成で存在する場合は、その差分を確認してから適用してください。

既存の `todos` テーブル・データ・RLSと `supabase-priority.sql` は維持しています。
新しい画面からTodoを操作する機能はありません。過去のHTMLはGit履歴に残ります。

## 初回の使い方

1. `outputs/index.html` をブラウザで開くか、公開URLへアクセスします。インターネット接続が必要です。
2. メールアドレスと6文字以上のパスワードを入力して「新規登録」します。
3. 確認メールが届いた場合はリンクを開き、同じメールアドレス・パスワードでログインします。
4. 「1. キーの位置」から問題を選びます。キー練習は日本語入力をオフ、日本語短文はオンにします。
5. 「開始」→文字を入力→変換を確定→「採点」の順で進めます。
6. 「保存しました」を確認してから「もう一度練習」または「次の問題」を選びます。

パスワードを忘れた場合は、メールアドレスを入力して「パスワードを忘れた方」を押します。
最新の再設定メールのリンクを開き、新しいパスワードを2回入力します。
`file://` からメールを送る場合、戻り先は公開URLです。公開済みの新しいHTMLが必要です。

保存失敗時は、結果をその画面に保持し「保存を再試行」を表示します。
未保存中は別の問題や再練習へ進めません。ログアウト時は破棄確認を表示します。
結果を保持するのは現在のページ内だけです。ブラウザ終了・再読み込み・認証切れでは失われるため、保存成功までページを閉じないでください。

## 採点と進捗

- 文字列をNFCに正規化し、CRLF/CRをLFへ統一します。
- Unicodeの文字単位で比較します。句読点・空白・全角半角は区別します。
- 誤り数は挿入・削除・置換の最小回数（編集距離）です。
- 正確率 = `100 × (1 − 誤り数 ÷ max(正解文字数, 入力文字数))`
- 速度 = `max(0, 正解文字数 − 誤り数) × 60000 ÷ 経過ミリ秒`
- 画面は小数1桁で表示しますが、習得判定は丸める前の値を使用します。
- 入力中の色は「現在の入力位置」の比較です。最終採点は挿入・削除を考慮した編集距離で計算します。
- 空入力と経過時間ゼロは保存しません。最終入力は最大2000文字です。
- 途中で修正した誤字は、最終入力の誤り数に含めません。
- 条件達成は連続3回でなくても有効です。習得済み状態は後の低得点で取り消しません。
- キーボード表示の利用有無を保存しますが、今回の習得条件は表示の有無を問いません。
  したがって「習得済み」は本アプリの数値条件の達成を示し、実際に手元を見ていないことの証明ではありません。
- 段階ごとの初期目標速度は15・25・35・25文字/分です。`exercises.target_speed` で問題ごとに調整できます。

## 保存・RLSの構成

`record_typing_attempt` RPCが、認証済みユーザーIDを `auth.uid()` から取得し、
公開中の問題を確認して、データベース側で採点し直します。
点数や所有者IDをブラウザから受け取りません。

1回のトランザクションで結果INSERTと進捗更新を行います。
ユーザーと問題の組み合わせで同時保存を直列化し、同じ結果IDの再送は既存の結果を返します。
同じIDで異なる内容を送った場合は拒否します。

一般ユーザーには3テーブルのSELECTだけを許可します。
公開問題は閲覧可能ですが、結果と進捗はRLSで本人に限定します。
書き込みは認証チェック付きのRPCのみです。通常のINSERT/UPDATE/DELETEは本人のデータでも拒否されます。
これは結果と進捗の不整合や点数の直接書き換えを防ぐためです。
問題管理はSupabaseの管理画面・SQLで行います。

経過時間はブラウザ計測であり、利用者自身が偽装することまでは防ぎません。競争用ランキングの仕組みではありません。
Secret key / service_role keyをHTMLに置かないでください。

## ローカルでの検証

実施した検証：
- PGlite 0.3.14（ローカルPostgreSQL互換環境）でSQL全体と再実行を検証
- 初期20問、既存Todo保持、Unicode採点、習得判定、同じ結果IDの再送を検証
- 進捗更新を意図的に失敗させ、結果INSERTも取り消されることを検証
- 2ユーザーと匿名ロールでRLS、未公開問題、直接書き込み拒否を検証
- Chrome + Playwrightで画面操作を検証（Supabase/Auth応答はテスト用の代替）
- 保存後に応答だけ失われたケースの再送、二重採点、IMEイベント、ユーザー切替を検証
- PC幅1280px・スマホ幅390pxで表示と横はみ出しを確認

本番SupabaseへのSQL適用、実際の確認メール、日本語OS IME、別PC同期、
GitHub Pagesへの公開はこのローカル検証に含みません。

開発用テストを再実行する場合のみ、Node.jsで次の依存関係を用意します。
アプリ利用者には不要です。ビルド処理はありません。

```powershell
npm install --prefix work/test-deps --no-save @electric-sql/pglite@0.3.14 playwright
$env:PGLITE_MODULE = (Resolve-Path work/test-deps/node_modules/@electric-sql/pglite).Path
$env:PLAYWRIGHT_MODULE = (Resolve-Path work/test-deps/node_modules/playwright).Path
node tests/database.cjs
node tests/browser.cjs
```

ブラウザテストは標準インストール先のChromeを使用します。
別の場所の場合は環境変数 `CHROME_PATH` にブラウザの実行ファイルを指定してください。
`tests/database.cjs` を先に実行するとブラウザテスト用の問題データが `work/` に生成されます。

## 公開後に確認すること

- 実際のメールで登録・確認・ログイン・パスワード再設定ができる
- OSの日本語IMEで、変換確定のEnterが採点にならない
- 同じ問題で正確率95%以上・目標速度以上を3回達成すると習得済みになる
- 再読み込み・再ログイン・別PCで同じ進捗を確認できる
- ネットワークをオフにして採点すると結果が残り、復旧後の再送で練習回数が1回だけ増える
- ユーザーAとBで問題を練習し、各自の結果だけが見える

RLSは画面表示だけでなく、開発者ツールのConsoleからも検証します。
ログインしたアプリ上の `client` は公開キーと現在のセッションを使います。
SQL Editorの管理者権限でSELECTするだけではRLSのテストになりません。

```javascript
// Bでログインし、Aの実際のユーザーIDを指定。dataが空配列であること。
await client.from('typing_attempts').select('*').eq('user_id', 'AのユーザーUUID');
await client.from('user_exercise_progress').select('*').eq('user_id', 'AのユーザーUUID');

// テスト専用の問題IDを指定。errorが返り、内容が変更されないこと。
await client.from('exercises').update({ title: '変更テスト' }).eq('id', 'テスト専用の問題UUID');
```

参考：[SupabaseのDatabase Functions](https://supabase.com/docs/guides/database/functions)、
[RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)、
[Authイベント](https://supabase.com/docs/reference/javascript/auth-onauthstatechange)。
