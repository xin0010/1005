-- AXG SHOP admin dashboard migration.
-- Run AFTER supabase-orders-schema.sql in the Supabase SQL Editor.
-- No service_role key or database secret belongs in ADMIN.HTML.

-- Admin membership can only be managed by a trusted database owner/operator.
create table if not exists public.shop_admins (
    user_id uuid primary key references auth.users (id) on delete cascade,
    created_at timestamptz not null default pg_catalog.now(),
    created_by uuid references auth.users (id) on delete set null
);

alter table public.shop_admins enable row level security;
revoke all on public.shop_admins from public, anon, authenticated;

-- Keep an immutable record of admin order-detail access. License keys are never
-- written to this audit table, and browser roles cannot read or edit the log.
create table if not exists public.shop_admin_audit_log (
    id bigint generated always as identity primary key,
    admin_user_id uuid not null,
    action text not null,
    order_id uuid,
    details jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default pg_catalog.now()
);

create index if not exists shop_admin_audit_log_order_created_idx
    on public.shop_admin_audit_log (order_id, created_at desc);

alter table public.shop_admin_audit_log enable row level security;
revoke all on public.shop_admin_audit_log from public, anon, authenticated;

-- Return high-level order and authorization metrics to verified admins only.
create or replace function public.admin_dashboard_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_result jsonb;
begin
    if (select auth.uid()) is null
       or not exists (
            select 1
            from public.shop_admins as a
            where a.user_id = (select auth.uid())
       ) then
        raise exception 'Admin access required' using errcode = '42501';
    end if;

    select pg_catalog.jsonb_build_object(
        'total_orders', (
            select pg_catalog.count(*)
            from public.orders as o
        ),
        'pending_orders', (
            select pg_catalog.count(*)
            from public.orders as o
            where o.status = 'pending'
        ),
        'paid_orders', (
            select pg_catalog.count(*)
            from public.orders as o
            where o.status = 'paid'
        ),
        'paid_revenue_twd', (
            select coalesce(pg_catalog.sum(o.total_amount), 0)
            from public.orders as o
            where o.status = 'paid'
        ),
        'active_authorizations', (
            select pg_catalog.count(*)
            from public.order_items as i
            join public.orders as o on o.id = i.order_id
            where o.status = 'paid'
              and i.authorization_status = 'active'
              and (i.expires_at is null or i.expires_at > pg_catalog.now())
        ),
        'pending_authorizations', (
            select pg_catalog.count(*)
            from public.order_items as i
            join public.orders as o on o.id = i.order_id
            where o.status = 'paid'
              and i.authorization_status = 'pending'
        ),
        'recent_orders', (
            select pg_catalog.count(*)
            from public.orders as o
            where o.created_at >= pg_catalog.now() - interval '7 days'
        )
    ) into v_result;

    return v_result;
end;
$$;

-- Search and paginate orders without granting direct table access to browsers.
create or replace function public.admin_list_orders(
    p_search text default null,
    p_status text default null,
    p_limit integer default 25,
    p_offset integer default 0
)
returns table (
    order_id uuid,
    order_number text,
    customer_email text,
    total_amount integer,
    status text,
    created_at timestamptz,
    line_count bigint,
    active_authorization_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_search text := nullif(pg_catalog.lower(pg_catalog.btrim(pg_catalog.left(coalesce(p_search, ''), 254))), '');
    v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
    v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
    if (select auth.uid()) is null
       or not exists (
            select 1
            from public.shop_admins as a
            where a.user_id = (select auth.uid())
       ) then
        raise exception 'Admin access required' using errcode = '42501';
    end if;

    if p_status is not null
       and p_status not in ('pending', 'paid', 'cancelled', 'refunded') then
        raise exception 'Invalid order status filter' using errcode = '22023';
    end if;

    return query
    select
        o.id,
        o.order_number,
        u.email::text,
        o.total_amount,
        o.status,
        o.created_at,
        pg_catalog.count(i.id)::bigint,
                pg_catalog.count(i.id) filter (
                        where o.status = 'paid'
                            and i.authorization_status = 'active'
                            and (i.expires_at is null or i.expires_at > pg_catalog.now())
        )::bigint
    from public.orders as o
    left join auth.users as u on u.id = o.user_id
    left join public.order_items as i on i.order_id = o.id
    where (p_status is null or o.status = p_status)
      and (
            v_search is null
            or pg_catalog.strpos(pg_catalog.lower(o.order_number), v_search) > 0
            or pg_catalog.strpos(pg_catalog.lower(coalesce(u.email, '')), v_search) > 0
      )
    group by o.id, o.order_number, u.email, o.total_amount, o.status, o.created_at
    order by o.created_at desc
    limit v_limit
    offset v_offset;
end;
$$;

-- License keys are returned only to verified admins, for paid orders with an
-- active, non-expired authorization. Each detail access is audited.
create or replace function public.admin_get_order_detail(p_order_id uuid)
returns table (
    order_id uuid,
    order_number text,
    customer_email text,
    total_amount integer,
    status text,
    created_at timestamptz,
    item_id uuid,
    product_name text,
    unit_price integer,
    quantity integer,
    authorization_status text,
    authorization_key text,
    expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
    if (select auth.uid()) is null
       or not exists (
            select 1
            from public.shop_admins as a
            where a.user_id = (select auth.uid())
       ) then
        raise exception 'Admin access required' using errcode = '42501';
    end if;

    if not exists (
        select 1
        from public.orders as o
        where o.id = p_order_id
    ) then
        return;
    end if;

    insert into public.shop_admin_audit_log (admin_user_id, action, order_id, details)
    values (
        (select auth.uid()),
        'view_order_detail',
        p_order_id,
        pg_catalog.jsonb_build_object('source', 'ADMIN.HTML')
    );

    return query
    select
        o.id,
        o.order_number,
        u.email::text,
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
    from public.orders as o
    left join auth.users as u on u.id = o.user_id
    left join public.order_items as i on i.order_id = o.id
    where o.id = p_order_id
    order by i.created_at asc, i.id asc;
end;
$$;

-- The dashboard may cancel only unpaid orders. Payment and refund states must
-- be driven by a verified payment-provider integration, never by this browser.
create or replace function public.admin_cancel_pending_order(
    p_order_id uuid,
    p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_updated_id uuid;
    v_reason text := nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_reason, '')), 500), '');
begin
    if (select auth.uid()) is null
       or not exists (
            select 1
            from public.shop_admins as a
            where a.user_id = (select auth.uid())
       ) then
        raise exception 'Admin access required' using errcode = '42501';
    end if;

    update public.orders as o
       set status = 'cancelled'
     where o.id = p_order_id
       and o.status = 'pending'
    returning o.id into v_updated_id;

    if v_updated_id is null then
        raise exception 'Only pending orders can be cancelled' using errcode = '22023';
    end if;

    update public.order_items as i
       set authorization_status = 'revoked',
           authorization_key = null
     where i.order_id = p_order_id
       and i.authorization_status = 'pending';

    insert into public.shop_admin_audit_log (admin_user_id, action, order_id, details)
    values (
        (select auth.uid()),
        'cancel_pending_order',
        p_order_id,
        pg_catalog.jsonb_build_object('reason', v_reason)
    );
end;
$$;

-- SECURITY DEFINER functions must not be executable by PUBLIC or anonymous users.
revoke all on function public.admin_dashboard_summary() from public, anon, authenticated;
revoke all on function public.admin_list_orders(text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_get_order_detail(uuid) from public, anon, authenticated;
revoke all on function public.admin_cancel_pending_order(uuid, text) from public, anon, authenticated;
grant usage on schema public to authenticated;
grant execute on function public.admin_dashboard_summary() to authenticated;
grant execute on function public.admin_list_orders(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_order_detail(uuid) to authenticated;
grant execute on function public.admin_cancel_pending_order(uuid, text) to authenticated;

-- Provision an administrator manually as the database owner in SQL Editor:
--   select id, email from auth.users where email = 'your-admin@example.com';
--   insert into public.shop_admins (user_id) values ('AUTH_USER_UUID');
-- Never add every authenticated user as an administrator.
