-- =====================================================================
-- 「回忆」模块 · Supabase 数据库结构
-- 在 Supabase 控制台 → SQL Editor 中,整段粘贴并运行即可。
--
-- 设计要点:
--   1. memories 表本身不对外开放(RLS 开启 + 撤销 anon 的直接权限)。
--   2. 所有读写都通过 SECURITY DEFINER 的 RPC 函数,
--      这样「答案 / 暗号」永远不会下发到前端,锁定的正文在解锁前也拿不到。
--   3. 预留了 kind、meta(jsonb)等字段,方便以后扩展图片、评论、时光胶囊。
-- =====================================================================

create extension if not exists "pgcrypto";  -- 用于 gen_random_uuid()

-- ---------- 表 ----------
create table if not exists public.memories (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'text',   -- 预留:text / image / video ...
  title       text,
  body        text not null,
  mode        text not null check (mode in ('public','question','passphrase','timed')),
  question    text,          -- 问题模式:问题
  answer      text,          -- 问题模式:答案(小写去空格存储)
  passphrase  text,          -- 暗号模式:暗号
  unlock_at   timestamptz,   -- 定时模式:开启时间
  images      text[] not null default '{}',        -- 配图 URL(存于 Supabase Storage)
  tags        text[] not null default '{}',        -- 标签
  meta        jsonb not null default '{}'::jsonb,  -- 预留扩展字段
  created_at  timestamptz not null default now()
);
-- 已有旧表时补上新列
alter table public.memories add column if not exists images text[] not null default '{}';
alter table public.memories add column if not exists tags   text[] not null default '{}';

create index if not exists memories_created_at_idx on public.memories (created_at desc);

alter table public.memories enable row level security;
-- 不给任何角色直接访问表的权限,全部走下面的函数
revoke all on public.memories from anon, authenticated;

-- ---------- 发布一篇回忆 ----------
drop function if exists public.create_memory(text,text,text,text,text,text,timestamptz);
drop function if exists public.create_memory(text,text,text,text,text,text,timestamptz,text[]);
create or replace function public.create_memory(
  p_body       text,
  p_mode       text default 'public',
  p_title      text default null,
  p_question   text default null,
  p_answer     text default null,
  p_passphrase text default null,
  p_unlock_at  timestamptz default null,
  p_images     text[] default '{}',
  p_tags       text[] default '{}'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_imgs text[] := coalesce(p_images, '{}');
  v_tags text[] := coalesce(p_tags, '{}');
begin
  if (p_body is null or length(btrim(p_body)) = 0)
     and coalesce(array_length(v_imgs, 1), 0) = 0 then
    raise exception '写点文字,或者加张图片吧';
  end if;
  if p_body is not null and length(p_body) > 20000 then
    raise exception '正文太长啦';
  end if;
  if coalesce(array_length(v_imgs, 1), 0) > 9 then
    raise exception '最多只能放 9 张图片';
  end if;
  if coalesce(array_length(v_tags, 1), 0) > 8 then
    raise exception '标签最多 8 个';
  end if;
  if p_mode not in ('public','question','passphrase','timed') then
    raise exception '无效的开启方式';
  end if;
  if p_mode = 'question'
     and (p_question is null or length(btrim(p_question)) = 0
          or p_answer is null or length(btrim(p_answer)) = 0) then
    raise exception '问题模式需要同时设置问题和答案';
  end if;
  if p_mode = 'passphrase'
     and (p_passphrase is null or length(btrim(p_passphrase)) = 0) then
    raise exception '暗号模式需要设置暗号';
  end if;
  if p_mode = 'timed' and p_unlock_at is null then
    raise exception '定时模式需要设置开启时间';
  end if;

  insert into public.memories (title, body, mode, question, answer, passphrase, unlock_at, images, tags)
  values (
    nullif(btrim(p_title), ''),
    coalesce(p_body, ''),
    p_mode,
    case when p_mode = 'question' then btrim(p_question) end,
    case when p_mode = 'question' then lower(btrim(p_answer)) end,
    case when p_mode = 'passphrase' then p_passphrase end,
    case when p_mode = 'timed' then p_unlock_at end,
    v_imgs,
    v_tags
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------- 列出回忆(不泄露锁定内容 / 答案 / 暗号) ----------
drop function if exists public.list_memories();
create or replace function public.list_memories()
returns table (
  id          uuid,
  kind        text,
  title       text,
  mode        text,
  question    text,          -- 只返回问题文字,不返回答案
  unlock_at   timestamptz,
  created_at  timestamptz,
  is_open     boolean,       -- 是否已可查看
  body        text,          -- 仅在已开启时返回,否则为 null
  images      text[],        -- 仅在已开启时返回配图,否则为空
  has_images  boolean,       -- 是否含配图(锁定态也可显示 📷 标记)
  tags        text[]         -- 标签(始终可见,便于搜索/筛选)
)
language sql
security definer
set search_path = public
as $$
  select
    m.id,
    m.kind,
    m.title,
    m.mode,
    m.question,
    m.unlock_at,
    m.created_at,
    (m.mode = 'public' or (m.mode = 'timed' and now() >= m.unlock_at)) as is_open,
    case
      when m.mode = 'public' or (m.mode = 'timed' and now() >= m.unlock_at)
      then m.body
      else null
    end as body,
    case
      when m.mode = 'public' or (m.mode = 'timed' and now() >= m.unlock_at)
      then m.images
      else '{}'::text[]
    end as images,
    coalesce(array_length(m.images, 1), 0) > 0 as has_images,
    m.tags
  from public.memories m
  order by m.created_at desc;
$$;

-- ---------- 尝试开启一篇回忆(问题 / 暗号 / 定时校验) ----------
-- 返回 jsonb: { "body": ..., "images": [...] }
drop function if exists public.open_memory(uuid, text);
create or replace function public.open_memory(p_id uuid, p_secret text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.memories;
  ok boolean := false;
begin
  select * into m from public.memories where id = p_id;
  if not found then
    raise exception '这篇回忆不存在';
  end if;

  if m.mode = 'public' then
    ok := true;
  elsif m.mode = 'timed' then
    if now() >= m.unlock_at then ok := true; else raise exception '还没到开启时间哦'; end if;
  elsif m.mode = 'question' then
    if lower(btrim(coalesce(p_secret, ''))) = m.answer then ok := true; else raise exception '答案不对哦,再想想~'; end if;
  elsif m.mode = 'passphrase' then
    if btrim(coalesce(p_secret, '')) = btrim(m.passphrase) then ok := true; else raise exception '暗号不对哦~'; end if;
  end if;

  if not ok then raise exception '无法开启'; end if;

  return jsonb_build_object('body', m.body, 'images', to_jsonb(m.images));
end;
$$;

-- ---------- 删除一篇回忆(公开可直接删;其它需通过解锁校验) ----------
create or replace function public.delete_memory(p_id uuid, p_secret text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.memories;
begin
  select * into m from public.memories where id = p_id;
  if not found then
    raise exception '这篇回忆不存在';
  end if;

  if m.mode = 'public' then
    delete from public.memories where id = p_id;
  elsif m.mode = 'timed' then
    if now() >= m.unlock_at then
      delete from public.memories where id = p_id;
    else
      raise exception '还没到开启时间,暂时不能删除';
    end if;
  elsif m.mode = 'question' then
    if lower(btrim(coalesce(p_secret, ''))) = m.answer then
      delete from public.memories where id = p_id;
    else
      raise exception '答案不对,不能删除';
    end if;
  elsif m.mode = 'passphrase' then
    if btrim(coalesce(p_secret, '')) = btrim(m.passphrase) then
      delete from public.memories where id = p_id;
    else
      raise exception '暗号不对,不能删除';
    end if;
  end if;
end;
$$;

-- =====================================================================
-- 评论 / 留言
--   comments 表跟随所属回忆一起删除(on delete cascade),
--   同样只走 SECURITY DEFINER 函数读写。
-- =====================================================================
create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  memory_id   uuid not null references public.memories(id) on delete cascade,
  parent_id   uuid references public.comments(id) on delete cascade,  -- 回复的目标留言
  author      text,          -- 昵称,可选
  body        text not null,
  created_at  timestamptz not null default now()
);
-- 已有旧表时补上 parent_id
alter table public.comments add column if not exists parent_id uuid references public.comments(id) on delete cascade;

create index if not exists comments_memory_idx on public.comments (memory_id, created_at);
create index if not exists comments_parent_idx on public.comments (parent_id);

alter table public.comments enable row level security;
revoke all on public.comments from anon, authenticated;

-- ---------- 列出某篇回忆的评论(含回复) ----------
drop function if exists public.list_comments(uuid);
create or replace function public.list_comments(p_memory_id uuid)
returns table (id uuid, parent_id uuid, author text, body text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select c.id, c.parent_id, c.author, c.body, c.created_at
  from public.comments c
  where c.memory_id = p_memory_id
  order by c.created_at asc;
$$;

-- ---------- 发表一条评论 / 回复 ----------
drop function if exists public.add_comment(uuid, text, text);
create or replace function public.add_comment(
  p_memory_id uuid,
  p_body      text,
  p_author    text default null,
  p_parent_id uuid default null
)
returns table (id uuid, parent_id uuid, author text, body text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.comments;
begin
  if p_body is null or length(btrim(p_body)) = 0 then
    raise exception '评论内容不能为空';
  end if;
  if length(p_body) > 2000 then
    raise exception '评论太长啦';
  end if;
  if not exists (select 1 from public.memories m where m.id = p_memory_id) then
    raise exception '这篇回忆不存在';
  end if;
  if p_parent_id is not null
     and not exists (select 1 from public.comments c
                     where c.id = p_parent_id and c.memory_id = p_memory_id) then
    raise exception '要回复的留言不存在';
  end if;

  insert into public.comments (memory_id, parent_id, author, body)
  values (
    p_memory_id,
    p_parent_id,
    nullif(btrim(coalesce(p_author, '')), ''),
    btrim(p_body)
  )
  returning * into r;

  return query select r.id, r.parent_id, r.author, r.body, r.created_at;
end;
$$;

-- ---------- 删除一条评论 ----------
create or replace function public.delete_comment(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.comments where id = p_id;
$$;

-- ---------- 授权匿名角色调用这些函数 ----------
grant execute on function public.create_memory(text,text,text,text,text,text,timestamptz,text[],text[]) to anon, authenticated;
grant execute on function public.list_memories() to anon, authenticated;
grant execute on function public.open_memory(uuid, text) to anon, authenticated;
grant execute on function public.delete_memory(uuid, text) to anon, authenticated;
grant execute on function public.list_comments(uuid) to anon, authenticated;
grant execute on function public.add_comment(uuid, text, text, uuid) to anon, authenticated;
grant execute on function public.delete_comment(uuid) to anon, authenticated;

-- =====================================================================
-- 图片存储:Supabase Storage
--   创建一个公开可读的 bucket,并允许匿名上传。
--   (图片 URL 存进 memories.images,是否可见由上面的函数控制)
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('memory-images', 'memory-images', true)
on conflict (id) do update set public = true;

-- 任何人都能读取(bucket 已公开,这条保证 RLS 下也能 select)
drop policy if exists "memory images public read" on storage.objects;
create policy "memory images public read"
  on storage.objects for select
  using (bucket_id = 'memory-images');

-- 允许匿名上传到该 bucket
drop policy if exists "memory images anon upload" on storage.objects;
create policy "memory images anon upload"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'memory-images');
