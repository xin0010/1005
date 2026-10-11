-- Run this migration in the Supabase SQL Editor.
-- This schema keeps order rows scoped to auth.uid() through Row Level Security (RLS).
-- Never expose the service_role key or database password in browser code.

create table if not exists public.orders (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    order_number text not null unique,
    total_amount integer not null check (total_amount >= 0),
    status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled', 'refunded')),
    created_at timestamptz not null default now()
);

create table if not exists public.order_items (
    id uuid primary key default gen_random_uuid(),
    order_id uuid not null references public.orders (id) on delete cascade,
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

create index if not exists orders_user_created_at_idx
    on public.orders (user_id, created_at desc);

create index if not exists order_items_order_id_idx
    on public.order_items (order_id);

alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Ensure logged-in members can read their own orders only.
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

-- Return only the signed-in member's orders. The license key is included only
-- for paid orders with an active, non-expired authorization.
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

-- Do not let browser clients read authorization_key directly from the tables.
revoke all on public.orders, public.order_items from public, anon, authenticated;
revoke all on function public.get_my_orders(text) from public, anon;
grant usage on schema public to authenticated;
grant execute on function public.get_my_orders(text) to authenticated;

-- IMPORTANT:
-- 1. Create orders and issue authorization keys only on a trusted server/Edge Function.
-- 2. Set user_id from the verified auth.uid() on the server; never trust a client-supplied user_id.
-- 3. Keep service_role, JWT signing secrets, and database credentials on the server only.
-- 4. The browser only calls get_my_orders(); direct table reads are revoked from browser roles.
