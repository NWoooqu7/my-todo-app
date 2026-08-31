-- Supabase DashboardのSQL Editorで実行してください。
-- 既存のRLS設定は変更せず、priorityカラムだけを追加・設定します。

begin;

alter table public.todos
  add column if not exists priority text;

-- 既存のTodoや想定外の値は「中」にそろえます。
update public.todos
set priority = 'medium'
where priority is null
   or priority not in ('soul', 'high', 'medium', 'low', 'absolute_zero');

alter table public.todos
  alter column priority set default 'medium',
  alter column priority set not null;

-- SQLを再実行しても同名制約のエラーにならないよう、いったん削除します。
alter table public.todos
  drop constraint if exists todos_priority_check;

alter table public.todos
  add constraint todos_priority_check
  check (priority in ('soul', 'high', 'medium', 'low', 'absolute_zero'));

commit;
