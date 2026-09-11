-- ことことタイピング 第1段階
-- Supabase SQL Editorで全体を実行。既存のtodosは変更しません。
-- このファイルは同じ構成への再実行が可能です。初期問題の変更も上書きしません。
begin;

create table if not exists public.exercises (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  prompt_text text not null,
  expected_input text not null check (char_length(expected_input) between 1 and 2000),
  exercise_type text not null check (exercise_type in ('key_drill', 'copy_typing')),
  difficulty smallint not null check (difficulty between 1 and 5),
  level smallint not null check (level between 1 and 4),
  category text not null,
  keyboard_hint_default boolean not null default true,
  target_speed numeric not null check (target_speed > 0 and target_speed < 10000),
  source_title text,
  character_name text,
  source_type text not null default 'original' check (source_type in ('original', 'licensed', 'public_domain')),
  display_order integer not null,
  is_published boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.typing_attempts (
  id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  exercise_id uuid not null references public.exercises(id),
  typed_text text not null check (char_length(typed_text) between 1 and 2000),
  elapsed_ms integer not null check (elapsed_ms > 0),
  total_characters integer not null check (total_characters > 0),
  error_count integer not null check (error_count >= 0),
  accuracy numeric not null check (accuracy between 0 and 100),
  typing_speed numeric not null check (typing_speed >= 0),
  hint_used boolean not null,
  started_at timestamptz not null,
  completed_at timestamptz not null check (completed_at >= started_at),
  primary key (user_id, id)
);
create index if not exists typing_attempts_user_exercise_idx
  on public.typing_attempts(user_id, exercise_id, completed_at desc);

create table if not exists public.user_exercise_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  exercise_id uuid not null references public.exercises(id),
  status text not null check (status in ('not_started', 'practicing', 'mastered')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  qualifying_attempt_count integer not null default 0
    check (qualifying_attempt_count between 0 and attempt_count),
  best_accuracy numeric not null default 0 check (best_accuracy between 0 and 100),
  best_speed numeric not null default 0 check (best_speed >= 0),
  last_practiced_at timestamptz,
  mastered_at timestamptz,
  primary key (user_id, exercise_id)
);

alter table public.exercises enable row level security;
alter table public.typing_attempts enable row level security;
alter table public.user_exercise_progress enable row level security;

-- 一般ユーザーはSELECTのみ。書き込みは認証チェック付きの専用関数に限定。
revoke all on public.exercises, public.typing_attempts, public.user_exercise_progress from public, anon, authenticated;
grant select on public.exercises, public.typing_attempts, public.user_exercise_progress to authenticated;

drop policy if exists typing_published_exercises on public.exercises;
create policy typing_published_exercises on public.exercises for select to authenticated
  using (is_published = true);
drop policy if exists typing_own_attempts on public.typing_attempts;
create policy typing_own_attempts on public.typing_attempts for select to authenticated
  using ((select auth.uid()) = user_id);
drop policy if exists typing_own_progress on public.user_exercise_progress;
create policy typing_own_progress on public.user_exercise_progress for select to authenticated
  using ((select auth.uid()) = user_id);

-- サーバー側でもNFC正規化と同じ採点を実施。ブラウザから点数を受け取りません。
create or replace function public.typing_normalize(p_text text)
returns text language sql immutable strict set search_path = ''
as $$ select normalize(replace(replace(p_text, E'\r\n', E'\n'), E'\r', E'\n'), NFC) $$;

create or replace function public.typing_edit_distance(p_left text, p_right text)
returns integer language plpgsql immutable strict set search_path = ''
as $$
declare
  previous integer[]; current_row integer[];
  i integer; j integer; n integer := char_length(p_left); m integer := char_length(p_right);
begin
  previous := array(select generate_series(0, m));
  for i in 1..n loop
    current_row := array[i];
    for j in 1..m loop
      current_row := array_append(current_row, least(
        current_row[j] + 1, previous[j+1] + 1,
        previous[j] + case when substr(p_left,i,1) = substr(p_right,j,1) then 0 else 1 end
      ));
    end loop;
    previous := current_row;
  end loop;
  return previous[m+1];
end;
$$;
revoke all on function public.typing_normalize(text) from public, anon, authenticated;
revoke all on function public.typing_edit_distance(text,text) from public, anon, authenticated;

-- 1回のRPC = 1トランザクション。結果と進捗が同時に成功/失敗します。
-- SECURITY DEFINERなので、所有者を必ずauth.uid()から取得し、
-- 未公開問題を拒否し、search_pathを固定します。
create or replace function public.record_typing_attempt(
  p_attempt_id uuid, p_exercise_id uuid, p_typed_text text, p_elapsed_ms integer,
  p_hint_used boolean, p_started_at timestamptz, p_completed_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
  exercise public.exercises%rowtype;
  attempt public.typing_attempts%rowtype;
  progress public.user_exercise_progress%rowtype;
  typed text; expected text; errors integer; typed_count integer;
  accuracy_value numeric; speed_value numeric; qualifies integer;
begin
  if owner_id is null then raise exception 'ログインが必要です' using errcode = '42501'; end if;
  if p_attempt_id is null or p_exercise_id is null or p_hint_used is null
    or p_typed_text is null or char_length(p_typed_text) not between 1 and 2000
    or p_elapsed_ms is null or p_elapsed_ms <= 0
    or p_started_at is null or p_completed_at is null or p_completed_at < p_started_at then
    raise exception '練習結果の値が不正です' using errcode = '22023';
  end if;
  typed := public.typing_normalize(p_typed_text);

  -- 同じユーザーの同じ問題への並行送信を直列化します。
  perform pg_advisory_xact_lock(hashtextextended(owner_id::text || ':' || p_exercise_id::text, 0));
  select * into attempt from public.typing_attempts where user_id = owner_id and id = p_attempt_id;
  if found then
    if attempt.exercise_id <> p_exercise_id or attempt.typed_text <> typed
      or attempt.elapsed_ms <> p_elapsed_ms or attempt.hint_used <> p_hint_used
      or attempt.started_at <> p_started_at or attempt.completed_at <> p_completed_at then
      raise exception '同じ結果IDを別の結果には使えません' using errcode = '22023';
    end if;
    select * into progress from public.user_exercise_progress
      where user_id = owner_id and exercise_id = attempt.exercise_id;
    return jsonb_build_object('attempt', to_jsonb(attempt), 'progress', to_jsonb(progress));
  end if;

  select * into exercise from public.exercises where id = p_exercise_id and is_published = true;
  if not found then raise exception '公開中の問題ではありません' using errcode = '42501'; end if;
  expected := public.typing_normalize(exercise.expected_input);
  errors := public.typing_edit_distance(expected, typed);
  typed_count := char_length(typed);
  accuracy_value := 100.0 * (1 - errors::numeric / greatest(char_length(expected), typed_count));
  speed_value := greatest(0, char_length(expected) - errors)::numeric * 60000 / p_elapsed_ms;
  qualifies := case when accuracy_value >= 95 and speed_value >= exercise.target_speed then 1 else 0 end;

  insert into public.typing_attempts (id,user_id,exercise_id,typed_text,elapsed_ms,total_characters,
    error_count,accuracy,typing_speed,hint_used,started_at,completed_at)
  values (p_attempt_id,owner_id,p_exercise_id,typed,p_elapsed_ms,typed_count,
    errors,accuracy_value,speed_value,p_hint_used,p_started_at,p_completed_at)
  returning * into attempt;

  insert into public.user_exercise_progress as p (user_id,exercise_id,status,attempt_count,
    qualifying_attempt_count,best_accuracy,best_speed,last_practiced_at,mastered_at)
  values (owner_id,p_exercise_id,'practicing',1,qualifies,accuracy_value,speed_value,p_completed_at,null)
  on conflict (user_id,exercise_id) do update set
    attempt_count = p.attempt_count + 1,
    qualifying_attempt_count = p.qualifying_attempt_count + qualifies,
    best_accuracy = greatest(p.best_accuracy,accuracy_value),
    best_speed = greatest(p.best_speed,speed_value),
    last_practiced_at = greatest(p.last_practiced_at,p_completed_at),
    status = case when p.status = 'mastered' or p.qualifying_attempt_count + qualifies >= 3
      then 'mastered' else 'practicing' end,
    mastered_at = case when p.mastered_at is not null then p.mastered_at
      when p.qualifying_attempt_count + qualifies >= 3 then p_completed_at else null end
  returning * into progress;
  return jsonb_build_object('attempt', to_jsonb(attempt), 'progress', to_jsonb(progress));
end;
$$;
revoke all on function public.record_typing_attempt(uuid,uuid,text,integer,boolean,timestamptz,timestamptz)
  from public, anon, authenticated;
grant execute on function public.record_typing_attempt(uuid,uuid,text,integer,boolean,timestamptz,timestamptz)
  to authenticated;

-- オリジナル問題20問。固定ID + ON CONFLICTで再実行しても重複しません。
insert into public.exercises (id,title,prompt_text,expected_input,exercise_type,difficulty,level,
  category,keyboard_hint_default,target_speed,display_order,is_published) values
  ('10000000-0000-4000-8000-000000000001','FとJを見つけよう','人差し指でFとJの突起を探し、ゆっくり交互に押しましょう。','fjfjfjfj','key_drill',1,1,'キーの位置',true,15,1,true),
  ('10000000-0000-4000-8000-000000000002','AとSの位置','左手の小指でA、薬指でS。目で場所を確かめて大丈夫です。','asasasas','key_drill',1,1,'キーの位置',true,15,2,true),
  ('10000000-0000-4000-8000-000000000003','DとKの位置','左手の中指でD、右手の中指でKを押しましょう。','dkdkdkdk','key_drill',1,1,'キーの位置',true,15,3,true),
  ('10000000-0000-4000-8000-000000000004','Lとセミコロン','右手の薬指でL、小指でセミコロンを押しましょう。','l;l;l;l;','key_drill',1,1,'キーの位置',true,15,4,true),
  ('10000000-0000-4000-8000-000000000005','スペースを入れよう','FとJの間に親指でスペースを入れてみましょう。','f j f j f j','key_drill',1,1,'キーの位置',true,15,5,true),
  ('10000000-0000-4000-8000-000000000006','左手のホームポジション','小指から人差し指へ、A S D Fの順で押しましょう。','asdf asdf asdf','key_drill',2,2,'ホームポジション',true,25,6,true),
  ('10000000-0000-4000-8000-000000000007','右手のホームポジション','人差し指から小指へ、J K L ;の順で押しましょう。','jkl; jkl; jkl;','key_drill',2,2,'ホームポジション',true,25,7,true),
  ('10000000-0000-4000-8000-000000000008','両手を交互に','一文字ごとに指をホームポジションへ戻しましょう。','aj sk dl f; aj sk dl f;','key_drill',2,2,'ホームポジション',true,25,8,true),
  ('10000000-0000-4000-8000-000000000009','中央のGとH','人差し指をG・Hに伸ばした後、F・Jへ戻しましょう。','fgf jhj fgf jhj','key_drill',2,2,'ホームポジション',true,25,9,true),
  ('10000000-0000-4000-8000-000000000010','ホームポジションのまとめ','速さは気にせず、左から右へ順番に入力しましょう。','asdf gh jkl; asdf gh jkl;','key_drill',2,2,'ホームポジション',true,25,10,true),
  ('10000000-0000-4000-8000-000000000011','短い単語：desk','キーボード表示を隠して挑戦。困ったら表示して確かめましょう。','desk desk desk','key_drill',3,3,'単語',false,35,11,true),
  ('10000000-0000-4000-8000-000000000012','短い単語：home','単語の区切りには親指でスペースを入れましょう。','home home home','key_drill',3,3,'単語',false,35,12,true),
  ('10000000-0000-4000-8000-000000000013','短い単語：note','打ち終えた指を、毎回ホームポジションへ戻しましょう。','note note note','key_drill',3,3,'単語',false,35,13,true),
  ('10000000-0000-4000-8000-000000000014','短い単語：team','一文字ずつ、正確に打つことを意識しましょう。','team team team','key_drill',3,3,'単語',false,35,14,true),
  ('10000000-0000-4000-8000-000000000015','短い単語：work','見ずに入力できるキーを少しずつ増やしましょう。','work work work','key_drill',3,3,'単語',false,35,15,true),
  ('10000000-0000-4000-8000-000000000016','一文字ずつ進もう','日本語入力をオンにして、句読点まで入力しましょう。','一文字ずつ、ゆっくり練習します。','copy_typing',4,4,'日本語の短文',false,25,16,true),
  ('10000000-0000-4000-8000-000000000017','今日の小さな目標','漢字へ変換して、確定してから採点しましょう。','今日の目標は、正確に入力することです。','copy_typing',4,4,'日本語の短文',false,25,17,true),
  ('10000000-0000-4000-8000-000000000018','練習を続けよう','短い文章を繰り返し入力して指を慣らしましょう。','少しずつ続けると、できることが増えます。','copy_typing',4,4,'日本語の短文',false,25,18,true),
  ('10000000-0000-4000-8000-000000000019','会議の予定','会議で使う文章の練習です。数字も半角で入力しましょう。','次の会議は、月曜日の10時からです。','copy_typing',4,4,'日本語の短文',false,25,19,true),
  ('10000000-0000-4000-8000-000000000020','決まったことを記録','決定事項を簡潔に記す練習です。最後の句点も忘れずに。','担当者は田中さんです。金曜日までに資料を共有します。','copy_typing',4,4,'日本語の短文',false,25,20,true)
on conflict (id) do nothing;
commit;
