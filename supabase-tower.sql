-- ことことの塔：supabase-typing.sql適用済みのDBへ追加実行
-- 既存Todo・過去の練習結果・RLSは削除/緩和しません。
begin;
alter table public.typing_attempts add column if not exists measurement jsonb;
alter table public.typing_attempts add column if not exists expected_snapshot text;
-- NULLの過去記録は新しい成長比較の対象外。
alter table public.exercises drop constraint if exists exercises_level_check;
alter table public.exercises add constraint exercises_level_check check(level between 1 and 8);
-- 初期短文だけを8階へ。正解文や既存の成績は変更しません。
update public.exercises set level=8,display_order=80+right(id::text,2)::int
where id in ('10000000-0000-4000-8000-000000000016','10000000-0000-4000-8000-000000000017','10000000-0000-4000-8000-000000000018','10000000-0000-4000-8000-000000000019','10000000-0000-4000-8000-000000000020') and level=4;
create or replace function public.record_typing_attempt_v2(
  p_attempt_id uuid, p_exercise_id uuid, p_typed_text text, p_elapsed_ms integer,
  p_hint_used boolean, p_started_at timestamptz, p_completed_at timestamptz,
  p_expected_input text, p_measurement jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
  exercise public.exercises%rowtype;
  attempt public.typing_attempts%rowtype;
  progress public.user_exercise_progress%rowtype;
  metric record;
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

  if p_measurement is null or jsonb_typeof(p_measurement) <> 'object'
    or p_measurement->>'version' is distinct from '1'
    or coalesce(p_measurement->>'source','') not in ('practice','guest','test')
    or coalesce(p_measurement->>'method','') not in ('direct','ime','assisted')
    or coalesce(p_measurement->>'corrections','') !~ '^[0-9]{1,6}$'
    or jsonb_typeof(p_measurement->'keys') is distinct from 'object'
    or octet_length(p_measurement::text)>20000 then
    raise exception '測定情報が不正です' using errcode='22023';
  end if;
  for metric in select * from jsonb_each(p_measurement->'keys') loop
    if char_length(metric.key)<>1 or jsonb_typeof(metric.value)<>'object'
      or coalesce(metric.value->>'attempts','') !~ '^[0-9]{1,6}$'
      or coalesce(metric.value->>'errors','') !~ '^[0-9]{1,6}$' then
      raise exception 'キー測定情報が不正です' using errcode='22023';
    end if;
    if (metric.value->>'errors')::int > (metric.value->>'attempts')::int then
      raise exception '誤入力数が試行数を超えています' using errcode='22023';
    end if;
  end loop;
  typed := public.typing_normalize(p_typed_text);

  -- 同じユーザーの同じ問題への並行送信を直列化します。
  perform pg_advisory_xact_lock(hashtextextended(owner_id::text || ':' || p_exercise_id::text, 0));
  select * into attempt from public.typing_attempts where user_id = owner_id and id = p_attempt_id;
  if found then
    if attempt.measurement is distinct from p_measurement
      or attempt.expected_snapshot is distinct from public.typing_normalize(p_expected_input)
      or attempt.exercise_id <> p_exercise_id or attempt.typed_text <> typed
      or attempt.elapsed_ms <> p_elapsed_ms or attempt.hint_used <> p_hint_used
      or attempt.started_at <> p_started_at or attempt.completed_at <> p_completed_at then
      raise exception '同じ結果IDを別の結果には使えません' using errcode = '22023';
    end if;
    select * into progress from public.user_exercise_progress
      where user_id = owner_id and exercise_id = attempt.exercise_id;
    return jsonb_build_object('attempt', to_jsonb(attempt), 'progress', case when progress.user_id is null then null else to_jsonb(progress) end);
  end if;

  select * into exercise from public.exercises where id = p_exercise_id and is_published = true;
  if not found then raise exception '公開中の問題ではありません' using errcode = '42501'; end if;
  expected := public.typing_normalize(exercise.expected_input);
  if expected is distinct from public.typing_normalize(p_expected_input) then
    raise exception '問題文が更新されています。再読み込みして練習してください' using errcode='22023';
  end if;
  errors := public.typing_edit_distance(expected, typed);
  typed_count := char_length(typed);
  accuracy_value := 100.0 * (1 - errors::numeric / greatest(char_length(expected), typed_count));
  speed_value := greatest(0, char_length(expected) - errors)::numeric * 60000 / p_elapsed_ms;
  qualifies := case when accuracy_value >= 95 and speed_value >= exercise.target_speed then 1 else 0 end;

  insert into public.typing_attempts (id,user_id,exercise_id,typed_text,elapsed_ms,total_characters,
    error_count,accuracy,typing_speed,hint_used,started_at,completed_at,measurement,expected_snapshot)
  values (p_attempt_id,owner_id,p_exercise_id,typed,p_elapsed_ms,typed_count,
    errors,accuracy_value,speed_value,p_hint_used,p_started_at,p_completed_at,p_measurement,expected)
  returning * into attempt;

  if p_measurement->>'source' = 'test' then
    select * into progress from public.user_exercise_progress where user_id=owner_id and exercise_id=p_exercise_id;
    return jsonb_build_object('attempt',to_jsonb(attempt),'progress',case when progress.user_id is null then null else to_jsonb(progress) end);
  end if;
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
revoke all on function public.record_typing_attempt_v2(uuid,uuid,text,integer,boolean,timestamptz,timestamptz,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.record_typing_attempt_v2(uuid,uuid,text,integer,boolean,timestamptz,timestamptz,text,jsonb)
  to authenticated;

insert into public.exercises(id,title,prompt_text,expected_input,exercise_type,difficulty,level,category,keyboard_hint_default,target_speed,display_order,is_published) values
('10000000-0000-4000-8000-000000000021','母音 1：aiueo','日本語入力はオフ。母音のキー a i u e o の位置を確かめましょう。 入力の手がかり：aiueo','aiueo','key_drill',3,4,'母音',true,15,40,true),
('10000000-0000-4000-8000-000000000022','母音 2：a i u e o','日本語入力はオフ。母音のキー a i u e o の位置を確かめましょう。 入力の手がかり：a i u e o','a i u e o','key_drill',3,4,'母音',true,15,41,true),
('10000000-0000-4000-8000-000000000023','母音 3：ai ai ue ue','日本語入力はオフ。母音のキー a i u e o の位置を確かめましょう。 入力の手がかり：ai ai ue ue','ai ai ue ue','key_drill',3,4,'母音',true,15,42,true),
('10000000-0000-4000-8000-000000000024','母音 4：oi oi ao ao','日本語入力はオフ。母音のキー a i u e o の位置を確かめましょう。 入力の手がかり：oi oi ao ao','oi oi ao ao','key_drill',3,4,'母音',true,15,43,true),
('10000000-0000-4000-8000-000000000025','母音 5：aiueo aiueo','日本語入力はオフ。母音のキー a i u e o の位置を確かめましょう。 入力の手がかり：aiueo aiueo','aiueo aiueo','key_drill',3,4,'母音',true,15,44,true),
('10000000-0000-4000-8000-000000000026','ひらがな 1：あいうえお','日本語入力をオンに。ローマ字入力でひらがなにして、Enterで確定しましょう。 入力の手がかり：aiueo','あいうえお','copy_typing',3,5,'ひらがな',false,15,50,true),
('10000000-0000-4000-8000-000000000027','ひらがな 2：かきくけこ','日本語入力をオンに。ローマ字入力でひらがなにして、Enterで確定しましょう。 入力の手がかり：kakikukeko','かきくけこ','copy_typing',3,5,'ひらがな',false,15,51,true),
('10000000-0000-4000-8000-000000000028','ひらがな 3：さしすせそ','日本語入力をオンに。ローマ字入力でひらがなにして、Enterで確定しましょう。 入力の手がかり：sashisuseso','さしすせそ','copy_typing',3,5,'ひらがな',false,15,52,true),
('10000000-0000-4000-8000-000000000029','ひらがな 4：たちつてと','日本語入力をオンに。ローマ字入力でひらがなにして、Enterで確定しましょう。 入力の手がかり：tachitsuteto','たちつてと','copy_typing',3,5,'ひらがな',false,15,53,true),
('10000000-0000-4000-8000-000000000030','ひらがな 5：なにぬねの','日本語入力をオンに。ローマ字入力でひらがなにして、Enterで確定しましょう。 入力の手がかり：naninuneno','なにぬねの','copy_typing',3,5,'ひらがな',false,15,54,true),
('10000000-0000-4000-8000-000000000031','小さい文字 1：きゃきゅきょ','日本語入力をオンに。kya→きゃ、sha→しゃ、kitte→きって。小さい文字を確定しましょう。 入力の手がかり：kyakyukyo','きゃきゅきょ','copy_typing',3,6,'小さい文字',false,15,60,true),
('10000000-0000-4000-8000-000000000032','小さい文字 2：しゃしゅしょ','日本語入力をオンに。kya→きゃ、sha→しゃ、kitte→きって。小さい文字を確定しましょう。 入力の手がかり：shashusho','しゃしゅしょ','copy_typing',3,6,'小さい文字',false,15,61,true),
('10000000-0000-4000-8000-000000000033','小さい文字 3：ちゃちゅちょ','日本語入力をオンに。kya→きゃ、sha→しゃ、kitte→きって。小さい文字を確定しましょう。 入力の手がかり：chachucho','ちゃちゅちょ','copy_typing',3,6,'小さい文字',false,15,62,true),
('10000000-0000-4000-8000-000000000034','小さい文字 4：きって','日本語入力をオンに。kya→きゃ、sha→しゃ、kitte→きって。小さい文字を確定しましょう。 入力の手がかり：kitte','きって','copy_typing',3,6,'小さい文字',false,15,63,true),
('10000000-0000-4000-8000-000000000035','小さい文字 5：ちょっと','日本語入力をオンに。kya→きゃ、sha→しゃ、kitte→きって。小さい文字を確定しましょう。 入力の手がかり：chotto','ちょっと','copy_typing',3,6,'小さい文字',false,15,64,true),
('10000000-0000-4000-8000-000000000036','変換 1：空','日本語入力をオンに。読みを入力→スペースで候補選択→Enterで確定。採点はボタンから。 入力の手がかり：そら','空','copy_typing',3,7,'変換',false,15,70,true),
('10000000-0000-4000-8000-000000000037','変換 2：山','日本語入力をオンに。読みを入力→スペースで候補選択→Enterで確定。採点はボタンから。 入力の手がかり：やま','山','copy_typing',3,7,'変換',false,15,71,true),
('10000000-0000-4000-8000-000000000038','変換 3：今日','日本語入力をオンに。読みを入力→スペースで候補選択→Enterで確定。採点はボタンから。 入力の手がかり：きょう','今日','copy_typing',3,7,'変換',false,15,72,true),
('10000000-0000-4000-8000-000000000039','変換 4：練習','日本語入力をオンに。読みを入力→スペースで候補選択→Enterで確定。採点はボタンから。 入力の手がかり：れんしゅう','練習','copy_typing',3,7,'変換',false,15,73,true),
('10000000-0000-4000-8000-000000000040','変換 5：会議','日本語入力をオンに。読みを入力→スペースで候補選択→Enterで確定。採点はボタンから。 入力の手がかり：かいぎ','会議','copy_typing',3,7,'変換',false,15,74,true)
on conflict(id) do nothing;
commit;
