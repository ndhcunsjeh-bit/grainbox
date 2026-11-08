-- ============================================================
-- 谷盒 GrainBox · 补丁 04：新增 DIMOO（泡泡玛特）IP + 藏品 + 标签
-- 用途：发现页 IP 导航需要 DIMOO，schema.sql 已经跑过，这里只补数据
-- 执行位置：Supabase Dashboard → SQL Editor → 粘贴全文 → Run
-- 全脚本幂等，重复执行不会报错、不会产生重复数据
-- ============================================================

-- 1. 新增系列（slug 用英文，用于 #/series/dimoo 路由）
insert into public.series (name, slug, description) values
  ('DIMOO', 'dimoo', '泡泡玛特原创 IP，云朵头小男孩')
on conflict (name) do nothing;

-- 1b. 补一张 DIMOO 展示图（挂到手办条目下，发现页 DIMOO 卡片顶部当横幅用）
insert into public.item_images (item_id, storage_path, alt, sort_order)
select x.id,
       'https://images.unsplash.com/photo-1607604276583-eef5d076aa5f?w=900&fit=crop&q=70',
       'DIMOO 收藏展示', 0
from (
  select i.id
  from public.items i
  join public.series s on s.id = i.series_id
  where s.slug = 'dimoo' and i.category = 'figure'
  order by i.name
  limit 1
) x
where not exists (select 1 from public.item_images g where g.item_id = x.id);

-- 2. 新增藏品（覆盖手办/景品/徽章/立牌/挂件，含限定与再版）
insert into public.items (series_id, name, category, edition, msrp, release_date)
select s.id, v.name, v.category, v.edition, v.msrp, v.release_date
from (values
  ('DIMOO', 'DIMOO 太空旅行系列 手办',        'figure', 'normal',  399.00, date '2024-09-21'),
  ('DIMOO', 'DIMOO 云朵精灵 限定手办',        'figure', 'limited', 599.00, date '2025-01-15'),
  ('DIMOO', 'DIMOO 动物王国 景品',            'prize',  'normal',  129.00, date '2024-11-08'),
  ('DIMOO', 'DIMOO 海底世界 徽章套组',        'badge',  'limited',  59.00, date '2024-07-12'),
  ('DIMOO', 'DIMOO 雨天小记 亚克力立牌',      'stand',  'normal',   49.00, date '2024-06-01'),
  ('DIMOO', 'DIMOO 梦境漫游 挂件',            'charm',  'reissue',  45.00, date '2025-03-01')
) as v(series_name, name, category, edition, msrp, release_date)
join public.series s on s.name = v.series_name
on conflict do nothing;

-- 3. 相关标签
insert into public.tags (name) values
  ('盲盒'), ('潮玩')
on conflict (name) do nothing;

-- 4. 标签关联（按分类挂对应标签，同时给 DIMOO 打「盲盒」「潮玩」）
insert into public.item_tags (item_id, tag_id)
select i.id, t.id
from public.items i
join public.series s on s.id = i.series_id
join public.tags t
  on (t.name = '手办' and i.category = 'figure')
  or (t.name = '景品' and i.category = 'prize')
  or (t.name = '徽章' and i.category = 'badge')
  or (t.name = '立牌' and i.category = 'stand')
  or (t.name = '挂件' and i.category = 'charm')
  or (t.name in ('盲盒', '潮玩') and s.name = 'DIMOO')
on conflict do nothing;

-- ============================================================
-- 校验：执行完应看到 DIMOO 系列 1 行、藏品 6 行
-- ============================================================
select s.name as 系列, count(i.id) as 藏品数
from public.series s
left join public.items i on i.series_id = s.id
where s.slug = 'dimoo'
group by s.name;
