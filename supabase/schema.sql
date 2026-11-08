-- ============================================================
-- 谷盒 GrainBox · 手办/谷子收藏管理平台 · 数据库迁移脚本
-- 依据：《软件需求规格说明书 GRAINBOX-SRS-001 V1.0》第 5 章 + 附录 A
-- 使用：Supabase 控制台 → SQL Editor → 新建查询 → 全文粘贴 → Run
-- 说明：本脚本首次执行即可；重复执行前请先在对应项目上清库
-- ============================================================

-- ---------- 0. 扩展 ----------
create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists pg_trgm;    -- 模糊搜索三元组索引

-- ============================================================
-- 1. 用户档案 profiles（与 auth.users 1:1）
-- ============================================================
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null check (char_length(nickname) between 1 and 24),
  avatar_url text,
  bio        text check (char_length(bio) <= 140),
  is_admin   boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is '用户档案：1:1 扩展 auth.users，存昵称/简介/头像/管理员标记';

-- ============================================================
-- 2. 系列 series
-- ============================================================
create table public.series (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(name) between 1 and 60),
  slug        text not null unique check (slug ~ '^[a-z0-9-]+$'),
  description text check (char_length(description) <= 500),
  cover_url   text,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.series is '作品/IP系列：图鉴的分类主线；name/slug 唯一；created_by SET NULL 保证公共数据不随创建者消失';

-- ============================================================
-- 3. 藏品条目 items
-- ============================================================
create table public.items (
  id           uuid primary key default gen_random_uuid(),
  series_id    uuid not null references public.series(id) on delete cascade,
  name         text not null check (char_length(name) between 1 and 80),
  category     text not null check (category in
                 ('figure','prize','badge','stand','charm','other')),
  edition      text not null default 'normal'
                 check (edition in ('normal','limited','reissue')),
  msrp         numeric(10,2) check (msrp >= 0),
  release_date date,
  cover_url    text,
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (series_id, name)              -- 同一系列下藏品不重名
);

comment on table public.items is '藏品条目：一款具体商品；series_id 外键级联；category/edition 用 CHECK 而非 enum 便于演进';

-- ============================================================
-- 4. 收藏记录 collections（多对多中间表 + 业务属性）★ 核心
-- ============================================================
create table public.collections (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid()
                 references public.profiles(id) on delete cascade,
  item_id      uuid not null references public.items(id) on delete cascade,
  status       text not null default 'wishlist'
                 check (status in ('owned','preorder','wishlist','sold')),
  price        numeric(10,2) check (price >= 0),
  currency     char(3) not null default 'CNY',
  source       text check (char_length(source) <= 40),
  purchased_at date,
  note         text check (char_length(note) <= 500),
  rating       smallint check (rating between 1 and 5),
  is_public    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (user_id, item_id)             -- 防重复收藏，兼作查询索引
);

comment on table public.collections is '收藏记录：user-item 多对多中间表，携带状态/价格/渠道等业务属性，兼有关系表与实体表双重身份';

-- ============================================================
-- 5. 标签 tags + 关联 item_tags（第二个多对多）
-- ============================================================
create table public.tags (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (char_length(name) between 1 and 20),
  created_at timestamptz not null default now()
);

create table public.item_tags (
  item_id    uuid not null references public.items(id) on delete cascade,
  tag_id     uuid not null references public.tags(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (item_id, tag_id)         -- 联合主键，无需额外代理键
);

comment on table public.tags      is '标签：独立实体（标签与藏品多对多）';
comment on table public.item_tags is '藏品-标签关联：联合主键防重复打标，双向级联';

-- ============================================================
-- 6. 藏品图片 item_images
-- ============================================================
create table public.item_images (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.items(id) on delete cascade,
  storage_path text not null unique,
  alt          text check (char_length(alt) <= 120),
  sort_order   smallint not null default 0,
  uploaded_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);

comment on table public.item_images is '藏品图片：数据库只存路径，二进制放 Storage；一件藏品多张图、可排序、可单独删除';

-- ============================================================
-- 7. 索引（SRS 表5-11，共 8 个）
-- ============================================================
-- 外键不会自动建索引，必须显式补
create index idx_items_series          on public.items (series_id);
create index idx_items_category        on public.items (category);
-- 模糊搜索走三元组索引
create index idx_items_name_trgm       on public.items using gin (name gin_trgm_ops);
-- 复合索引列顺序：最左列选择性高
create index idx_collections_user_status on public.collections (user_id, status);
create index idx_collections_user_created on public.collections (user_id, created_at desc);
create index idx_collections_item      on public.collections (item_id);
create index idx_tags_name             on public.tags (name);
create index idx_item_tags_tag         on public.item_tags (tag_id);

-- ============================================================
-- 8. 触发器函数
-- ============================================================

-- 8.1 新用户注册 → 自动创建 profiles
create or replace function public.fn_handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, nickname)
  values (new.id, split_part(new.email, '@', 1))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.fn_handle_new_user();

-- 8.2 更新时间戳（任何写入路径都触发）
create or replace function public.fn_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_profiles_touch     before update on public.profiles    for each row execute function public.fn_touch_updated_at();
create trigger trg_series_touch       before update on public.series      for each row execute function public.fn_touch_updated_at();
create trigger trg_items_touch        before update on public.items       for each row execute function public.fn_touch_updated_at();
create trigger trg_collections_touch  before update on public.collections for each row execute function public.fn_touch_updated_at();

-- ============================================================
-- 9. 函数
-- ============================================================

-- 9.1 管理员判定（security definer，避免策略递归）
create or replace function public.fn_is_admin()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

-- 9.2 看板聚合函数：一次 RPC 返回全部看板数据（总数/状态分布/系列分布/支出）
create or replace function public.fn_dashboard(p_user uuid)
returns json
language plpgsql
stable
security invoker
as $$
declare
  result json;
begin
  select json_build_object(
    'stats', (
      select json_build_object(
        'total',       count(*),
        'owned',       count(*) filter (where status = 'owned'),
        'preorder',    count(*) filter (where status = 'preorder'),
        'wishlist',    count(*) filter (where status = 'wishlist'),
        'sold',        count(*) filter (where status = 'sold'),
        'total_spend', coalesce(sum(price) filter (where status = 'owned'), 0)
      )
      from public.collections
      where user_id = p_user
    ),
    'by_series', (
      select coalesce(json_agg(s), '[]'::json) from (
        select s.name as name, count(*) as cnt
        from public.collections c
        join public.items  i on i.id = c.item_id
        join public.series s on s.id = i.series_id
        where c.user_id = p_user
        group by s.name
        order by cnt desc
      ) s
    )
  ) into result;
  return result;
end;
$$;

-- ============================================================
-- 10. 视图（必须 security_invoker，否则会绕过基表 RLS）
-- ============================================================

-- 10.1 我的收藏统计
create or replace view public.v_collection_stats
with (security_invoker = on) as
select
  c.user_id,
  count(*)                                                     as total_count,
  count(*) filter (where c.status = 'owned')                   as owned_count,
  count(*) filter (where c.status = 'preorder')                as preorder_count,
  count(*) filter (where c.status = 'wishlist')                as wishlist_count,
  count(*) filter (where c.status = 'sold')                    as sold_count,
  coalesce(sum(c.price) filter (where c.status = 'owned'), 0)  as total_spend
from public.collections c
group by c.user_id;

-- 10.2 系列统计（首页卡片用：藏品数 + 公开收藏数）
create or replace view public.v_series_stats
with (security_invoker = on) as
select
  s.id          as series_id,
  s.name,
  s.slug,
  s.description,
  s.cover_url,
  count(distinct i.id)       as item_count,
  count(c.id)                as public_collection_count
from public.series s
left join public.items i        on i.series_id = s.id
left join public.collections c  on c.item_id = i.id and c.is_public = true
group by s.id, s.name, s.slug, s.description, s.cover_url;

-- ============================================================
-- 11. RLS 行级安全
-- 原则：默认拒绝；公共数据可读、私有数据隔离；写权限按角色分层
-- ============================================================
alter table public.profiles    enable row level security;
alter table public.series      enable row level security;
alter table public.items       enable row level security;
alter table public.collections enable row level security;
alter table public.tags        enable row level security;
alter table public.item_tags   enable row level security;
alter table public.item_images enable row level security;

-- ---------- profiles：公开可读（不含敏感字段），本人可改，禁自我提权 ----------
create policy profiles_select_all on public.profiles
  for select to anon, authenticated using (true);
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- 列级授权：只许改 nickname/avatar_url/bio，禁止改 is_admin（防自我提权，SRS NFR-S08）
revoke update on public.profiles from authenticated;
grant  update (nickname, avatar_url, bio) on public.profiles to authenticated;

-- ---------- series / items / tags / item_tags / item_images：公开读，管理员写 ----------
create policy series_select_all  on public.series    for select to anon, authenticated using (true);
create policy series_write_admin on public.series    for all to authenticated using (public.fn_is_admin()) with check (public.fn_is_admin());

create policy items_select_all   on public.items     for select to anon, authenticated using (true);
create policy items_write_admin  on public.items     for all to authenticated using (public.fn_is_admin()) with check (public.fn_is_admin());

create policy tags_select_all    on public.tags      for select to anon, authenticated using (true);
create policy tags_insert_all    on public.tags      for insert to authenticated with check (true);  -- 允许用户自助加标签
create policy tags_update_admin  on public.tags      for update to authenticated using (public.fn_is_admin());
create policy tags_delete_admin  on public.tags      for delete to authenticated using (public.fn_is_admin());

create policy item_tags_select_all  on public.item_tags for select to anon, authenticated using (true);
create policy item_tags_write_admin on public.item_tags for all to authenticated using (public.fn_is_admin()) with check (public.fn_is_admin());

create policy item_images_select_all  on public.item_images for select to anon, authenticated using (true);
create policy item_images_write_admin on public.item_images for all to authenticated using (public.fn_is_admin()) with check (public.fn_is_admin());

-- ---------- collections：本人或公开可读，本人可写 ----------
create policy collections_select_own on public.collections
  for select to authenticated
  using (user_id = auth.uid() or is_public = true);
create policy collections_insert_own on public.collections
  for insert to authenticated
  with check (user_id = auth.uid());
create policy collections_update_own on public.collections
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy collections_delete_own on public.collections
  for delete to authenticated
  using (user_id = auth.uid());

-- ============================================================
-- 12. Storage 存储桶 + 策略
-- ============================================================
insert into storage.buckets (id, name, public) values
  ('covers',  'covers',  true),
  ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- covers：公开读，管理员写
create policy covers_read  on storage.objects for select to anon, authenticated using (bucket_id = 'covers');
create policy covers_write on storage.objects for insert to authenticated with check (bucket_id = 'covers' and public.fn_is_admin());

-- avatars：公开读，本人写自己的（路径首段 = 本人 uid）
create policy avatars_read  on storage.objects for select to anon, authenticated using (bucket_id = 'avatars');
create policy avatars_write on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============================================================
-- 13. 种子数据（登录后页面不空；按 SRS 表8-1 精简版）
-- ============================================================

-- 系列（10 个，含 slug）
insert into public.series (name, slug, description) values
  ('原神',           'genshin',           '米哈游开放世界 RPG'),
  ('崩坏：星穹铁道', 'honkai-star-rail',  '米哈游太空幻想 RPG'),
  ('新世纪福音战士', 'evangelion',        '庵野秀明经典机战'),
  ('海贼王',         'one-piece',         '尾田荣一郎长篇漫画'),
  ('火影忍者',       'naruto',            '岸本齐史忍者漫画'),
  ('初音未来',       'hatsune-miku',      '虚拟歌手，万年顶流'),
  ('孤独摇滚',       'bocchi-the-rock',   '芳文社乐队番'),
  ('咒术回战',       'jujutsu-kaisen',    'Jump 系人气作品'),
  ('我的英雄学院',   'my-hero-academia',  '英雄题材热血漫画'),
  ('赛马娘',         'uma-musume',        'Cygames 赛马拟人')
on conflict (name) do nothing;

-- 藏品（覆盖 figure/prize/badge/stand/charm/other 与 edition）
insert into public.items (series_id, name, category, edition, msrp, release_date)
select s.id, v.name, v.category, v.edition, v.msrp, v.release_date
from (values
  ('原神',           '雷电将军·稻妻雷光 手办', 'figure', 'normal',   1299.00, date '2024-06-01'),
  ('原神',           '胡桃·蝶引来生 景品',     'prize',  'normal',    129.00, date '2024-03-15'),
  ('原神',           '派蒙 亚克力立牌',        'stand',  'normal',     59.00, date '2023-12-01'),
  ('原神',           '可莉 徽章套组',          'badge',  'limited',    45.00, date '2024-07-20'),
  ('原神',           '旅行者 挂件',            'charm',  'normal',     39.00, date '2024-01-10'),
  ('崩坏：星穹铁道', '流萤 手办',              'figure', 'limited',   1499.00, date '2025-02-14'),
  ('崩坏：星穹铁道', '三月七 景品',             'prize',  'normal',    119.00, date '2024-11-01'),
  ('崩坏：星穹铁道', '星 亚克力立牌',           'stand',  'reissue',    55.00, date '2025-01-01'),
  ('新世纪福音战士', '绫波丽 1/7 手办',        'figure', 'normal',   1380.00, date '2023-08-01'),
  ('新世纪福音战士', '初号机 景品',             'prize',  'normal',    139.00, date '2024-04-01'),
  ('新世纪福音战士', '明日香 徽章',            'badge',  'limited',    49.00, date '2024-09-01'),
  ('海贼王',         '路飞 手办',              'figure', 'normal',    899.00, date '2024-05-01'),
  ('海贼王',         '索隆 景品',              'prize',  'normal',    109.00, date '2024-08-01'),
  ('海贼王',         '草帽团 立牌套装',         'stand',  'limited',   129.00, date '2024-10-01'),
  ('火影忍者',       '鸣人 手办',              'figure', 'normal',    799.00, date '2024-02-01'),
  ('火影忍者',       '佐助 徽章',              'badge',  'normal',     39.00, date '2024-06-01'),
  ('初音未来',       '初音未来 Magical Mirai 手办', 'figure', 'limited', 1280.00, date '2024-08-30'),
  ('初音未来',       '初音未来 樱花ver. 吧唧',  'badge',  'normal',     35.00, date '2024-04-01'),
  ('初音未来',       '初音未来 挂件',           'charm',  'normal',     45.00, date '2024-03-01'),
  ('孤独摇滚',       '后藤一里 手办',           'figure', 'normal',    980.00, date '2024-10-01'),
  ('孤独摇滚',       '虹夏&凉 徽章套组',        'badge',  'normal',     55.00, date '2024-02-20'),
  ('孤独摇滚',       '波奇酱 亚克力立牌',       'stand',  'normal',     49.00, date '2024-05-01'),
  ('咒术回战',       '五条悟 景品',             'prize',  'normal',    119.00, date '2024-05-10'),
  ('咒术回战',       '虎杖悠仁 手办',           'figure', 'normal',    890.00, date '2024-09-01'),
  ('我的英雄学院',   '绿谷出久 手办',           'figure', 'normal',    760.00, date '2024-01-01'),
  ('我的英雄学院',   '爆豪胜己 徽章',           'badge',  'limited',    42.00, date '2024-07-01'),
  ('赛马娘',         '特别周 手办',             'figure', 'normal',   1150.00, date '2024-06-15'),
  ('赛马娘',         '无声铃鹿 景品',           'prize',  'normal',    129.00, date '2024-11-01')
) as v(series_name, name, category, edition, msrp, release_date)
join public.series s on s.name = v.series_name
on conflict do nothing;

-- 标签（12 个）
insert into public.tags (name) values
  ('限定'), ('再版'), ('景品'), ('特典'), ('痛包'), ('亚克力'),
  ('抱枕'), ('手办'), ('徽章'), ('立牌'), ('挂件'), ('色纸')
on conflict (name) do nothing;

-- 藏品-标签关联（示例）
insert into public.item_tags (item_id, tag_id)
select i.id, t.id
from public.items i
join public.tags t on t.name in ('手办', '徽章', '立牌', '挂件')
where (i.category = 'figure' and t.name = '手办')
   or (i.category = 'badge'  and t.name = '徽章')
   or (i.category = 'stand'  and t.name = '立牌')
   or (i.category = 'charm'  and t.name = '挂件')
on conflict do nothing;

-- ============================================================
-- 完成。
-- 提示：注册第一个账号后，如需要管理员权限，请在 SQL Editor 执行：
--   update public.profiles set is_admin = true where id = '你的用户 uuid';
-- ============================================================
