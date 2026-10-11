begin;

create table if not exists public.shop_products (
    id integer primary key check (id > 0),
    name text not null,
    category text not null,
    price integer not null check (price > 0 and price <= 500000),
    tag text not null default '',
    description text not null default '',
    active boolean not null default true
);

insert into public.shop_products (id, name, category, price, tag, description) values
    (1, 'PUBG 絕地求生 透視輔助 (30天)', 'pubg', 1200, '穩定防封', '支援透視、物品顯示、預判自瞄與無後座力，即時雲端過安全檢測。'),
    (2, 'Free Fire 雙端雲端直裝外掛 (30天)', 'mobile', 800, '手遊首選', 'iOS / Android 雙端支援，免越獄免Root，包含自動鎖頭、透視顯敵與人物加速。'),
    (3, '傳說對決 iOS 專用安全透視 (永久授權)', 'mobile', 1200, '蘋果專用', '全地圖視野顯敵、技能冷卻顯示、野怪血量計算，穩定不封號。'),
    (4, '蘋果 P12 證書個人獨立簽名 (1年保固)', 'account', 650, '獨立憑證', '個人獨享企業開發者證書，支援所有 IPA 直裝應用，提供一年內掉簽補簽服務。')
on conflict (id) do nothing;

alter table public.shop_products enable row level security;
revoke all on public.shop_products from public, anon, authenticated;

create or replace function public.get_shop_products()
returns table (
    id integer,
    name text,
    category text,
    price integer,
    tag text,
    description text
)
language sql
stable
security definer
set search_path = ''
as $$
    select p.id, p.name, p.category, p.price, p.tag, p.description
    from public.shop_products as p
    where p.active = true
    order by p.id;
$$;

revoke all on function public.get_shop_products() from public, anon, authenticated;
grant usage on schema public to anon, authenticated;
grant execute on function public.get_shop_products() to anon, authenticated;

commit;