# 谷盒 GrainBox · 手办/谷子收藏管理平台

课程作业：带 Supabase 数据库的信息管理系统。
技术栈：**Supabase（Auth + PostgreSQL + RLS + Storage + 视图/函数/触发器）** + 原生 HTML/CSS/JS（无构建，可部署 GitHub Pages）。

配套文档：《软件需求规格说明书 GRAINBOX-SRS-001 V1.0》（需求基线）、《docs/数据库设计说明.md》（本文档的数据库详解）。

## 文件结构

```
后端/
├── index.html              # 前端应用（单文件，hash 路由，对齐 SRS 页面结构）
├── supabase/schema.sql     # 建表脚本（7 表 + 索引 + 视图 + 函数 + 触发器 + RLS + Storage + 种子数据）
├── docs/数据库设计说明.md    # 数据库设计文档（答辩/PPT 素材）
├── 谷盒-手办谷子收藏管理-需求规格说明书-V1.0.docx   # 需求基线（SRS）
└── README.md
```

## 部署步骤（3 步）

### 1. 建库
Supabase 控制台 → **SQL Editor** → New query → 粘贴 `supabase/schema.sql` 全文 → **Run**。
自动建好 7 张表、8 个索引、2 个统计视图、函数、触发器、RLS、Storage 桶，并预置 10 个系列、28 件藏品、12 个标签。

### 2. 配置前端
打开 `index.html`，把顶部 `SUPABASE_ANON_KEY = "__ANON_KEY__"` 替换为你的 **anon/public key**（控制台 → Settings → API）。URL 已填好。

### 3. 设置管理员（可选）
注册第一个账号后，在 SQL Editor 执行：
```sql
update public.profiles set is_admin = true where id = '你的用户 uuid';
```
（uuid 在 Table Editor 的 profiles 表里能看到）之后刷新，导航栏会出现「管理」入口。

## 功能清单（对齐 SRS 第 4 章）

- **首页**：系列卡片墙（含藏品数），顶部搜索（FR-06/27）
- **系列详情**：按分类分组展示藏品（FR-07）
- **藏品详情**：信息 + 多图 + 公开收藏数 + 加入收藏（FR-08/11/12）
- **晒谷墙**：is_public 收藏动态流（FR-10）
- **我的收藏**：状态页签筛选 + 关键词搜索 + 编辑/删除/状态流转（FR-13/14/15/16/18）
- **看板**：统计卡片 + 系列/状态分布条形图，数据来自 fn_dashboard RPC（FR-19~22）
- **档案**：改昵称/简介，头像上传（canvas 压缩到 webp）（FR-03/04）
- **管理**：系列/藏品/标签维护（FR-30~33）
- **登录注册**：Supabase Auth 邮箱验证

## 注意事项

- Supabase 新项目默认开启「邮箱确认」，注册后需去邮箱点确认才能登录。测试嫌麻烦可在 Authentication → Providers → Email 关掉 **Confirm email**。
- anon key 是公开密钥，随前端分发，安全靠 RLS 保证；**service_role key 永远不能写进前端**。
- 数据库字段用英文枚举（owned/preorder/wishlist/sold 等），展示层映射中文——这是 SRS 5.3 与 7.8 的约定。
