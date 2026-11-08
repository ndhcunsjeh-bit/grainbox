-- ============================================================
-- 谷盒 GrainBox · 补丁 05：我的谷库（用户自建图片库）
-- 执行位置：Supabase Dashboard → SQL Editor → 粘贴全文 → Run
-- 幂等：可重复执行，不会报错、不会重复建对象
--
-- 设计说明：
--   1. collection_images 挂在 collections 下，而不是 item_images
--      —— 用户拍的是「我这件谷子」，属于个人收藏记录，不是公共图鉴条目
--   2. user_id 冗余存一份，RLS 直接按它过滤，避免每次 join collections
--   3. 部分唯一索引保证「一件收藏只能有一张封面」
--   4. 触发器：第一张自动成为封面 + 每件最多 20 张 + 只能给自己的收藏传图
--   5. 视图 v_my_library 一次 join 出「收藏 + 藏品 + 系列 + 封面 + 照片数」
-- ============================================================

-- ------------------------------------------------------------
-- 1. 表：collection_images
-- ------------------------------------------------------------
create table if not exists public.collection_images (
  id            uuid primary key default gen_random_uuid(),
  collection_id uuid not null references public.collections(id) on delete cascade,
  user_id       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  storage_path  text not null unique check (char_length(storage_path) between 1 and 300),
  alt           text check (char_length(alt) <= 120),
  sort_order    smallint not null default 0,
  is_cover      boolean not null default false,
  created_at    timestamptz not null default now()
);

comment on table public.collection_images is
  '用户实拍图：属于某条收藏记录，二进制存 Storage(my-shots)，库里只存路径；删收藏级联删图';

comment on column public.collection_images.is_cover is
  '是否作为谷库卡片封面；同一 collection_id 下最多一张（部分唯一索引保证）';

-- 同一收藏内只能有一张封面
create unique index if not exists uq_collection_cover
  on public.collection_images (collection_id) where is_cover;

create index if not exists idx_ci_collection on public.collection_images (collection_id, sort_order);
create index if not exists idx_ci_user       on public.collection_images (user_id);

-- ------------------------------------------------------------
-- 2. 触发器：第一张自动当封面 / 上限 20 张 / 只能传自己的收藏
-- ------------------------------------------------------------
create or replace function public.fn_shot_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cnt       int;
  has_cover boolean;
begin
  -- 只能给自己的收藏上传
  if not exists (
    select 1 from public.collections
    where id = new.collection_id and user_id = new.user_id
  ) then
    raise exception '只能给自己的收藏上传图片';
  end if;

  select count(*), coalesce(bool_or(is_cover), false)
    into cnt, has_cover
  from public.collection_images
  where collection_id = new.collection_id;

  if cnt >= 20 then
    raise exception '每件藏品最多上传 20 张实拍图';
  end if;

  -- 第一张照片自动成为封面
  if not has_cover then
    new.is_cover := true;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_shot_before_insert on public.collection_images;
create trigger trg_shot_before_insert
  before insert on public.collection_images
  for each row execute function public.fn_shot_before_insert();

-- ------------------------------------------------------------
-- 3. RLS：自己全权，别人只看公开收藏的封面
-- ------------------------------------------------------------
alter table public.collection_images enable row level security;

drop policy if exists ci_select_own on public.collection_images;
create policy ci_select_own on public.collection_images
  for select to authenticated
  using (user_id = auth.uid());

-- 别人的图：只有「公开收藏 + 标记为封面」的那一张可见（广场用）
drop policy if exists ci_select_public_cover on public.collection_images;
create policy ci_select_public_cover on public.collection_images
  for select to authenticated
  using (
    is_cover = true
    and exists (
      select 1 from public.collections c
      where c.id = collection_images.collection_id and c.is_public = true
    )
  );

drop policy if exists ci_insert_own on public.collection_images;
create policy ci_insert_own on public.collection_images
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists ci_update_own on public.collection_images;
create policy ci_update_own on public.collection_images
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists ci_delete_own on public.collection_images;
create policy ci_delete_own on public.collection_images
  for delete to authenticated
  using (user_id = auth.uid());

-- 注意：is_cover 的切换要「先全部置 false，再置 true」，
-- 否则中间态会撞上 uq_collection_cover 唯一索引。

-- ------------------------------------------------------------
-- 4. Storage 桶：my-shots（公开读，路径首段 = 本人 uid）
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('my-shots', 'my-shots', true)
on conflict (id) do nothing;

drop policy if exists my_shots_read   on storage.objects;
drop policy if exists my_shots_insert on storage.objects;
drop policy if exists my_shots_update on storage.objects;
drop policy if exists my_shots_delete on storage.objects;

create policy my_shots_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'my-shots');

create policy my_shots_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'my-shots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy my_shots_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'my-shots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy my_shots_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'my-shots'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ------------------------------------------------------------
-- 5. 视图：v_my_library（谷库页一次查全）
--    security_invoker = on：按调用者权限执行，不会绕过基表 RLS
-- ------------------------------------------------------------
create or replace view public.v_my_library
with (security_invoker = on) as
select
  c.id            as collection_id,
  c.user_id,
  c.status,
  c.price,
  c.currency,
  c.purchased_at,
  c.source,
  c.note,
  c.rating,
  c.is_public,
  c.updated_at,
  i.id            as item_id,
  i.name          as item_name,
  i.category,
  i.edition,
  i.cover_url,
  i.msrp,
  s.name          as series_name,
  s.slug          as series_slug,
  (
    select count(*) from public.collection_images ci
    where ci.collection_id = c.id
  ) as photo_count,
  (
    select ci.storage_path from public.collection_images ci
    where ci.collection_id = c.id
    order by ci.is_cover desc, ci.sort_order, ci.created_at
    limit 1
  ) as cover_photo
from public.collections c
join public.items  i on i.id = c.item_id
join public.series s on s.id = i.series_id
-- 只出「我」的记录：collections 的 select 策略允许看别人的公开收藏，
-- 这里必须自己收口，否则别人的公开收藏会混进我的谷库
where c.user_id = auth.uid();

comment on view public.v_my_library is
  '我的谷库：收藏 + 藏品 + 系列 + 封面图 + 照片数，一次查询给前端';

-- ============================================================
-- 校验：执行完应看到 1 张表、1 个视图、4 条策略、1 个桶
-- ============================================================
select 'table' as 类型, count(*) as 数量
from information_schema.tables
where table_schema = 'public' and table_name = 'collection_images'
union all
select 'view', count(*)
from information_schema.views
where table_schema = 'public' and table_name = 'v_my_library'
union all
select 'policy', count(*)
from pg_policies
where schemaname = 'public' and tablename = 'collection_images'
union all
select 'bucket', count(*)
from storage.buckets
where id = 'my-shots';
