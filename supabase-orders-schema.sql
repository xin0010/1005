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
    (1, 'PUBG 絕地求生 透視輔助 (30天)', 'pubg', 1000, '穩定防封', '支援透視、物品顯示、預判自瞄與無後座力，即時雲端過安全檢測。'),
    (2, 'Free Fire 雙端雲端直裝外掛 (30天)', 'mobile', 800, '手遊首選', 'iOS / Android 雙端支援，免越獄免Root，包含自動鎖頭、透視顯敵與人物加速。'),
    (3, '傳說對決 iOS 專用安全透視 (永久授權)', 'mobile', 1000, '蘋果專用', '全地圖視野顯敵、技能冷卻顯示、野怪血量計算，穩定不封號。'),
    (4, '蘋果 P12 證書個人獨立簽名 (1年保固)', 'account', 150, '獨立憑證', '個人獨享企業開發者證書，支援所有 IPA 直裝應用，提供一年內掉簽補簽服務。')
on conflict (id) do nothing;

create table if not exists public.orders (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    order_number text not null unique,
    request_id uuid,
    total_amount integer not null check (total_amount >= 0),
    status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled', 'refunded')),
    created_at timestamptz not null default now()
);

create table if not exists public.order_items (
    id uuid primary key default gen_random_uuid(),
    order_id uuid not null references public.orders (id) on delete cascade,
    product_id integer references public.shop_products (id),
    product_name text not null,
    unit_price integer not null check (unit_price >= 0),
    quantity integer not null default 1 check (quantity > 0),
    authorization_status text not null default 'pending' check (authorization_status in ('pending', 'active', 'expired', 'revoked')),
    authorization_key text,
    expires_at timestamptz,
    created_at timestamptz not null default now(),
    constraint active_authorization_has_key check (
        authorization_status <> 'active' or authorization_key is not null
    )
);

alter table public.orders add column if not exists request_id uuid;
alter table public.order_items add column if not exists product_id integer references public.shop_products (id);

create unique index if not exists orders_user_request_id_uq
    on public.orders (user_id, request_id)
    where request_id is not null;

create index if not exists orders_user_created_at_idx
    on public.orders (user_id, created_at desc);

create index if not exists order_items_order_id_idx
    on public.order_items (order_id);

alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.shop_products enable row level security;

do $$
begin
    if not exists (
        select 1 from pg_policies
        where schemaname = 'public' and tablename = 'orders' and policyname = 'Members can read their own orders'
    ) then
        create policy "Members can read their own orders"
            on public.orders for select to authenticated
            using ((select auth.uid()) = user_id);
    end if;

    if not exists (
        select 1 from pg_policies
        where schemaname = 'public' and tablename = 'order_items' and policyname = 'Members can read their own order items'
    ) then
        create policy "Members can read their own order items"
            on public.order_items for select to authenticated
            using (
                exists (
                    select 1 from public.orders
                    where orders.id = order_items.order_id
                      and orders.user_id = (select auth.uid())
                )
            );
    end if;
end
$$;

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

create or replace function public.create_my_order(
    p_items jsonb,
    p_expected_total integer,
    p_request_id uuid
)
returns table (
    order_id uuid,
    order_number text,
    total_amount integer,
    order_status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_entry jsonb;
    v_items jsonb := '[]'::jsonb;
    v_priced_items jsonb := '[]'::jsonb;
    v_existing_items jsonb;
    v_seen_ids integer[] := array[]::integer[];
    v_id_text text;
    v_quantity_text text;
    v_product_id integer;
    v_quantity integer;
    v_product record;
    v_existing public.orders%rowtype;
    v_order_id uuid;
    v_order_number text;
    v_total bigint := 0;
begin
    if v_user_id is null then
        raise exception '登入才能下單' using errcode = '42501';
    end if;
    if p_request_id is null or p_expected_total is null or p_expected_total <= 0 then
        raise exception '訂單請求格式錯誤' using errcode = '22023';
    end if;
    if p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array'
       or pg_catalog.jsonb_array_length(p_items) not between 1 and 20 then
        raise exception '商品明細必須包含 1 至 20 種商品' using errcode = '22023';
    end if;

    for v_entry in select value from pg_catalog.jsonb_array_elements(p_items) as items(value) loop
        if pg_catalog.jsonb_typeof(v_entry) <> 'object'
           or pg_catalog.jsonb_typeof(v_entry->'id') <> 'number'
           or pg_catalog.jsonb_typeof(v_entry->'quantity') <> 'number' then
            raise exception '商品明細格式錯誤' using errcode = '22023';
        end if;

        v_id_text := v_entry->>'id';
        v_quantity_text := v_entry->>'quantity';
        if v_id_text !~ '^[1-9][0-9]{0,8}$' or v_quantity_text !~ '^([1-9]|[1-9][0-9])$' then
            raise exception '商品識別或數量無效' using errcode = '22023';
        end if;
        v_product_id := v_id_text::integer;
        v_quantity := v_quantity_text::integer;
        if v_product_id = any(v_seen_ids) then
            raise exception '商品不可重複提交' using errcode = '22023';
        end if;
        v_seen_ids := pg_catalog.array_append(v_seen_ids, v_product_id);
        v_items := v_items || pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object('id', v_product_id, 'quantity', v_quantity)
        );
    end loop;

    select coalesce(pg_catalog.jsonb_agg(item.value order by (item.value->>'id')::integer), '[]'::jsonb)
    into v_items
    from pg_catalog.jsonb_array_elements(v_items) as item(value);

    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_user_id::text || ':' || p_request_id::text, 0)
    );
    select o.* into v_existing
    from public.orders as o
    where o.user_id = v_user_id and o.request_id = p_request_id;

    if found then
        select coalesce(
            pg_catalog.jsonb_agg(
                pg_catalog.jsonb_build_object('id', i.product_id, 'quantity', i.quantity)
                order by i.product_id
            ), '[]'::jsonb
        ) into v_existing_items
        from public.order_items as i
        where i.order_id = v_existing.id;

        if v_existing_items <> v_items then
            raise exception '此請求識別碼對應不同的購物車' using errcode = '22023';
        end if;
        return query select v_existing.id, v_existing.order_number,
            v_existing.total_amount, v_existing.status;
        return;
    end if;

    for v_entry in select value from pg_catalog.jsonb_array_elements(v_items) as items(value) loop
        v_product_id := (v_entry->>'id')::integer;
        v_quantity := (v_entry->>'quantity')::integer;
        select p.name, p.price into v_product
        from public.shop_products as p
        where p.id = v_product_id and p.active = true
        for share;

        if not found then
            raise exception '商品已下架，請重新載入商品目錄' using errcode = '22023';
        end if;
        v_total := v_total + v_product.price::bigint * v_quantity;
        v_priced_items := v_priced_items || pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object('id', v_product_id, 'name', v_product.name,
                'price', v_product.price, 'quantity', v_quantity)
        );
    end loop;

    if v_total <> p_expected_total or v_total > 2147483647 then
        raise exception '價格已變更，請重新載入商品目錄' using errcode = '22023';
    end if;

    v_order_id := pg_catalog.gen_random_uuid();
    v_order_number := 'AXG-' || pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDD') || '-'
        || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(v_order_id::text, '-', ''), 1, 12));

    insert into public.orders (id, user_id, order_number, request_id, total_amount, status)
    values (v_order_id, v_user_id, v_order_number, p_request_id, v_total::integer, 'pending');

    for v_entry in select value from pg_catalog.jsonb_array_elements(v_priced_items) as items(value) loop
        insert into public.order_items (
            order_id, product_id, product_name, unit_price, quantity, authorization_status
        ) values (
            v_order_id, (v_entry->>'id')::integer, v_entry->>'name',
            (v_entry->>'price')::integer, (v_entry->>'quantity')::integer, 'pending'
        );
    end loop;

    return query select v_order_id, v_order_number, v_total::integer, 'pending'::text;
end;
$$;

create or replace function public.get_my_orders(p_order_number text default null)
returns table (
    order_id uuid,
    order_number text,
    total_amount integer,
    order_status text,
    created_at timestamptz,
    item_id uuid,
    product_name text,
    unit_price integer,
    quantity integer,
    authorization_status text,
    authorization_key text,
    expires_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select
        o.id,
        o.order_number,
        o.total_amount,
        o.status,
        o.created_at,
        i.id,
        i.product_name,
        i.unit_price,
        i.quantity,
        case
            when i.authorization_status = 'active'
                 and i.expires_at is not null
                 and i.expires_at <= pg_catalog.now()
                then 'expired'
            else i.authorization_status
        end,
        case
            when o.status = 'paid'
                 and i.authorization_status = 'active'
                 and (i.expires_at is null or i.expires_at > pg_catalog.now())
                then i.authorization_key
            else null
        end,
        i.expires_at
        from (
                select source_order.*
                from public.orders as source_order
                where source_order.user_id = (select auth.uid())
                    and (
                            p_order_number is null
                            or source_order.order_number = pg_catalog.upper(pg_catalog.regexp_replace(pg_catalog.btrim(p_order_number), '^#', '', 'i'))
                    )
                order by source_order.created_at desc
                limit 50
        ) as o
    left join public.order_items as i on i.order_id = o.id
        order by o.created_at desc;
$$;

revoke all on public.shop_products, public.orders, public.order_items from public, anon, authenticated;
revoke all on function public.get_shop_products() from public, anon, authenticated;
revoke all on function public.create_my_order(jsonb, integer, uuid) from public, anon, authenticated;
revoke all on function public.get_my_orders(text) from public, anon, authenticated;
grant usage on schema public to anon, authenticated;
grant execute on function public.get_shop_products() to anon, authenticated;
grant execute on function public.create_my_order(jsonb, integer, uuid) to authenticated;
grant execute on function public.get_my_orders(text) to authenticated;
