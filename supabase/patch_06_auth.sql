-- ============================================================
-- 谷盒 GrainBox · 补丁 06：账户安全（验证码注册 / 重置密码 / 登录审计）
-- 执行位置：Supabase Dashboard → SQL Editor → 粘贴全文 → Run
-- 幂等：可重复执行
--
-- ⚠️ 这个补丁只改数据库，还必须在 Dashboard 配两封邮件模板，
--    否则验证码不会出现在邮件里（前端拿不到 6 位数字）。
--    位置：Authentication → Emails（旧版在 Project Settings → Auth）
--    1) Confirm signup 模板里加一行：<b>{{ .Token }}</b>
--    2) Reset Password 模板里加一行：<b>{{ .Token }}</b>
--       （保留原来的 {{ .ConfirmationURL }} 也可以，链接和验证码两条路都能用）
--    注意：用 Supabase 自带 SMTP 时每小时只能发 2~3 封，测试别狂点，
--          正式用请配自己的 SMTP（Authentication → SMTP Settings）。
--
-- 关于「密码加密」的说明（重要，别改）：
--   本站前端从头到尾不保存、不传输、不落库任何明文密码。
--   注册/登录时密码由 supabase-js 通过 HTTPS 直接送到 Supabase Auth，
--   由 Auth 服务用 bcrypt（blowfish，每用户独立 salt，cost=10）单向哈希后
--   写入 auth.users.encrypted_password。这个哈希不可逆，连数据库管理员
--   也拿不到明文；本站自己的业务表里不存在任何密码字段。
--   所以本补丁只记录「登录信息（谁、什么时候、从什么设备）」，
--   绝不复制密码或密码哈希——那样做才是真正的不安全。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 登录审计表：只记事件，不记密码
--    外键指向 auth.users 而不是 profiles：
--    注册瞬间 profiles 行可能还没建好，指向 auth.users 才能保证
--    「注册成功就一定留下一条 signup 记录」
-- ------------------------------------------------------------
create table if not exists public.login_logs (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  email      text not null default '',
  event      text not null check (event in ('signup', 'login', 'reset', 'logout')),
  user_agent text check (char_length(user_agent) <= 200),
  created_at timestamptz not null default now()
);

comment on table public.login_logs is
  '登录审计：注册/登录/重置/退出事件。刻意不含任何密码或密码哈希字段';
comment on column public.login_logs.event is
  'signup 由 auth.users 触发器自动写；login/reset/logout 由前端登录成功后调 fn_log_login 写';

create index if not exists idx_login_logs_user on public.login_logs (user_id, created_at desc);
create index if not exists idx_login_logs_time on public.login_logs (created_at desc);

alter table public.login_logs enable row level security;

-- 自己的登录记录自己可读
drop policy if exists ll_select_own on public.login_logs;
create policy ll_select_own on public.login_logs
  for select to authenticated
  using (user_id = auth.uid());

-- 管理员可读全部（用户账户页要用）
drop policy if exists ll_select_admin on public.login_logs;
create policy ll_select_admin on public.login_logs
  for select to authenticated
  using (public.fn_is_admin());

-- 故意不建 insert/update/delete 策略：客户端一行都写不进来，
-- 写入只能走下面的 security definer 函数和触发器。

-- ------------------------------------------------------------
-- 2. 注册事件：auth.users 新行 = 注册成功，自动留痕
-- ------------------------------------------------------------
create or replace function public.fn_log_signup()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.login_logs (user_id, email, event)
  values (new.id, coalesce(new.email, ''), 'signup');
  return new;
end;
$$;

drop trigger if exists trg_log_signup on auth.users;
create trigger trg_log_signup
  after insert on auth.users
  for each row execute function public.fn_log_signup();

-- ------------------------------------------------------------
-- 3. 登录/重置/退出：前端登录成功后调一次
--    security definer + 只允许 authenticated，anon 无法刷日志
-- ------------------------------------------------------------
create or replace function public.fn_log_login(p_event text default 'login', p_ua text default null)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_ev    text := coalesce(nullif(p_event, ''), 'login');
begin
  if v_uid is null then
    return;                                  -- 未登录直接忽略，不报错
  end if;
  if v_ev not in ('signup', 'login', 'reset', 'logout') then
    v_ev := 'login';
  end if;

  select coalesce(u.email, '') into v_email from auth.users u where u.id = v_uid;

  insert into public.login_logs (user_id, email, event, user_agent)
  values (v_uid, v_email, v_ev, nullif(left(coalesce(p_ua, ''), 200), ''));
end;
$$;

revoke all on function public.fn_log_login(text, text) from public, anon;
grant execute on function public.fn_log_login(text, text) to authenticated;

-- ------------------------------------------------------------
-- 4. 用户账户总表（管理员专用 RPC）
--    把 auth.users 里的登录信息（邮箱、注册时间、最后登录、是否验证）
--    连同 profiles 的昵称/管理员标记、login_logs 的登录次数一次给出。
--    密码只回一个「算法名」，绝不回哈希本身。
-- ------------------------------------------------------------
create or replace function public.fn_list_accounts()
returns table (
  id               uuid,
  email            text,
  nickname         text,
  is_admin         boolean,
  signed_up_at     timestamptz,
  last_sign_in_at  timestamptz,
  email_confirmed  boolean,
  password_algo    text,
  login_count      bigint,
  last_login_at    timestamptz
)
language plpgsql
stable
security definer set search_path = public
as $$
begin
  if not public.fn_is_admin() then
    raise exception '只有管理员可以查看用户账户';
  end if;

  return query
  select
    u.id,
    coalesce(u.email, '')::text,
    coalesce(p.nickname, '未命名'),
    coalesce(p.is_admin, false),
    u.created_at,
    u.last_sign_in_at,
    (u.email_confirmed_at is not null),
    case
      when u.encrypted_password like '$2a$%' then 'bcrypt ($2a)'
      when u.encrypted_password like '$2b$%' then 'bcrypt ($2b)'
      when coalesce(u.encrypted_password, '') = '' then '无密码（第三方登录）'
      else '其它'
    end::text,
    (select count(*) from public.login_logs l
      where l.user_id = u.id and l.event = 'login'),
    (select max(l.created_at) from public.login_logs l
      where l.user_id = u.id and l.event = 'login')
  from auth.users u
  left join public.profiles p on p.id = u.id
  order by u.created_at desc;
end;
$$;

revoke all on function public.fn_list_accounts() from public, anon;
grant execute on function public.fn_list_accounts() to authenticated;

-- 最近登录流水（管理员看板用，限 50 条）
create or replace function public.fn_recent_logins(p_limit int default 50)
returns table (
  email       text,
  nickname    text,
  event       text,
  user_agent  text,
  created_at  timestamptz
)
language plpgsql
stable
security definer set search_path = public
as $$
begin
  if not public.fn_is_admin() then
    raise exception '只有管理员可以查看登录记录';
  end if;

  return query
  select l.email, coalesce(p.nickname, '未命名'), l.event, l.user_agent, l.created_at
  from public.login_logs l
  left join public.profiles p on p.id = l.user_id
  order by l.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

revoke all on function public.fn_recent_logins(int) from public, anon;
grant execute on function public.fn_recent_logins(int) to authenticated;

-- ============================================================
-- 校验：应看到 table=1、policy=2、3 个函数
-- ============================================================
select 'table' as 类型, count(*)::text as 数量
from information_schema.tables
where table_schema = 'public' and table_name = 'login_logs'
union all
select 'policy', count(*)::text
from pg_policies
where schemaname = 'public' and tablename = 'login_logs'
union all
select 'function', count(*)::text
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('fn_log_login', 'fn_list_accounts', 'fn_recent_logins', 'fn_log_signup');
