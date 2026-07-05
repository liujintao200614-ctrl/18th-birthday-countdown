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
  meta        jsonb not null default '{}'::jsonb,  -- 预留扩展字段
  created_at  timestamptz not null default now()
);

create index if not exists memories_created_at_idx on public.memories (created_at desc);

alter table public.memories enable row level security;
-- 不给任何角色直接访问表的权限,全部走下面的函数
revoke all on public.memories from anon, authenticated;

-- ---------- 发布一篇回忆 ----------
create or replace function public.create_memory(
  p_body       text,
  p_mode       text default 'public',
  p_title      text default null,
  p_question   text default null,
  p_answer     text default null,
  p_passphrase text default null,
  p_unlock_at  timestamptz default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_body is null or length(btrim(p_body)) = 0 then
    raise exception '正文不能为空';
  end if;
  if length(p_body) > 20000 then
    raise exception '正文太长啦';
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

  insert into public.memories (title, body, mode, question, answer, passphrase, unlock_at)
  values (
    nullif(btrim(p_title), ''),
    p_body,
    p_mode,
    case when p_mode = 'question' then btrim(p_question) end,
    case when p_mode = 'question' then lower(btrim(p_answer)) end,
    case when p_mode = 'passphrase' then p_passphrase end,
    case when p_mode = 'timed' then p_unlock_at end
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------- 列出回忆(不泄露锁定内容 / 答案 / 暗号) ----------
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
  body        text           -- 仅在已开启时返回,否则为 null
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
    end as body
  from public.memories m
  order by m.created_at desc;
$$;

-- ---------- 尝试开启一篇回忆(问题 / 暗号 / 定时校验) ----------
create or replace function public.open_memory(p_id uuid, p_secret text default null)
returns text
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
    return m.body;
  elsif m.mode = 'timed' then
    if now() >= m.unlock_at then
      return m.body;
    else
      raise exception '还没到开启时间哦';
    end if;
  elsif m.mode = 'question' then
    if lower(btrim(coalesce(p_secret, ''))) = m.answer then
      return m.body;
    else
      raise exception '答案不对哦,再想想~';
    end if;
  elsif m.mode = 'passphrase' then
    if btrim(coalesce(p_secret, '')) = btrim(m.passphrase) then
      return m.body;
    else
      raise exception '暗号不对哦~';
    end if;
  end if;

  raise exception '无法开启';
end;
$$;

-- ---------- 授权匿名角色调用这三个函数 ----------
grant execute on function public.create_memory(text,text,text,text,text,text,timestamptz) to anon, authenticated;
grant execute on function public.list_memories() to anon, authenticated;
grant execute on function public.open_memory(uuid, text) to anon, authenticated;
