-- ============================================================
-- 补丁：修复种子数据中 item_tags 的 tag_id 类型错误
-- 错误原因：insert 时传了 t.name（text），而 item_tags.tag_id 是 uuid
-- 用法：在已执行过 schema.sql（前 400 行成功）的库上，单独跑这一份即可
-- ============================================================

-- 清掉可能已部分写入的错误关联（若有）
truncate table public.item_tags;

-- 重新按 category 与标签名建立关联，tag_id 用 t.id（uuid）
insert into public.item_tags (item_id, tag_id)
select i.id, t.id
from public.items i
join public.tags t
  on (i.category = 'figure' and t.name = '手办')
  or (i.category = 'badge'  and t.name = '徽章')
  or (i.category = 'stand'  and t.name = '立牌')
  or (i.category = 'charm'  and t.name = '挂件')
on conflict do nothing;

-- 校验：应返回若干行关联数
select t.name as "标签", count(*) as "关联藏品数"
from public.item_tags it
join public.tags t on t.id = it.tag_id
group by t.name
order by count(*) desc;
