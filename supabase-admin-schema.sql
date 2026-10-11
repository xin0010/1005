begin;

alter table public.shop_products add column if not exists image_file text not null default 'logo-700x700.png';
alter table public.shop_products add column if not exists revision integer not null default 1;

create sequence if not exists public.shop_product_id_seq as integer start with 1000;
alter sequence public.shop_product_id_seq owned by public.shop_products.id;
alter table public.shop_products alter column id set default pg_catalog.nextval('public.shop_product_id_seq'::pg_catalog.regclass);
select pg_catalog.setval(
    'public.shop_product_id_seq'::pg_catalog.regclass,
    pg_catalog.greatest(
        (select coalesce(pg_catalog.max(p.id), 0) from public.shop_products as p),
        (select last_value from public.shop_product_id_seq),
        999
    )
);
revoke all on sequence public.shop_product_id_seq from public, anon, authenticated;

create table if not exists public.shop_admins (
    user_id uuid primary key references auth.users (id) on delete cascade,
    created_at timestamptz not null default pg_catalog.now(),
    created_by uuid references auth.users (id) on delete set null
);

alter table public.shop_admins enable row level security;
revoke all on public.shop_admins from public, anon, authenticated;

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

create unique index if not exists shop_admin_payment_reference_uq
    on public.shop_admin_audit_log (pg_catalog.upper(details->>'reference'))
    where action = 'confirm_payment' and details ? 'reference';

alter table public.shop_admin_audit_log enable row level security;
revoke all on public.shop_admin_audit_log from public, anon, authenticated;

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

create or replace function public.admin_confirm_order_payment(
    p_order_id uuid,
    p_reference text,
    p_funds_verified boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_reference text := pg_catalog.upper(pg_catalog.btrim(coalesce(p_reference, '')));
    v_updated_id uuid;
begin
    if (select auth.uid()) is null
       or not exists (
            select 1 from public.shop_admins as a
            where a.user_id = (select auth.uid())
       ) then
        raise exception 'Admin access required' using errcode = '42501';
    end if;

    if p_funds_verified is distinct from true
       or pg_catalog.length(v_reference) not between 8 and 80
       or v_reference !~ '^[A-Za-z0-9_-]+$' then
        raise exception 'Verified payment reference required' using errcode = '22023';
    end if;

    update public.orders as o
       set status = 'paid'
     where o.id = p_order_id
       and o.status = 'pending'
    returning o.id into v_updated_id;

    if v_updated_id is null then
        raise exception 'Only pending orders can be confirmed' using errcode = '22023';
    end if;

    insert into public.shop_admin_audit_log (admin_user_id, action, order_id, details)
    values (
        (select auth.uid()),
        'confirm_payment',
        v_updated_id,
        pg_catalog.jsonb_build_object('reference', v_reference, 'source', 'ADMIN')
    );
end;
$$;

create or replace function public.admin_list_products(
    p_search text default null,
    p_status text default null,
    p_limit integer default 25,
    p_offset integer default 0
)
returns table (
    id integer,
    name text,
    category text,
    price integer,
    tag text,
    description text,
    image_file text,
    active boolean,
    revision integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_search text := nullif(pg_catalog.lower(pg_catalog.btrim(pg_catalog.left(coalesce(p_search, ''), 160))), '');
    v_limit integer := pg_catalog.least(pg_catalog.greatest(coalesce(p_limit, 25), 1), 100);
    v_offset integer := pg_catalog.greatest(coalesce(p_offset, 0), 0);
begin
    if (select auth.uid()) is null
       or not exists (
            select 1 from public.shop_admins as a
            where a.user_id = (select auth.uid())
       ) then
        raise exception 'Admin access required' using errcode = '42501';
    end if;

    if p_status is not null and p_status not in ('active', 'inactive') then
        raise exception 'Invalid product status filter' using errcode = '22023';
    end if;

    return query
    select p.id, p.name, p.category, p.price, p.tag, p.description, p.image_file, p.active, p.revision
    from public.shop_products as p
    where (p_status is null or p.active = (p_status = 'active'))
      and (v_search is null
        or pg_catalog.strpos(pg_catalog.lower(p.name), v_search) > 0
        or pg_catalog.strpos(pg_catalog.lower(p.category), v_search) > 0
        or pg_catalog.strpos(p.id::text, v_search) > 0)
    order by p.id desc
    limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_save_product(
    p_product_id integer,
    p_name text,
    p_category text,
    p_price integer,
    p_tag text,
    p_description text,
    p_image_file text,
    p_active boolean,
    p_expected_revision integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_name text := pg_catalog.btrim(coalesce(p_name, ''));
    v_tag text := pg_catalog.btrim(coalesce(p_tag, ''));
    v_description text := pg_catalog.btrim(coalesce(p_description, ''));
    v_image_file text := pg_catalog.btrim(coalesce(p_image_file, ''));
    v_before public.shop_products%rowtype;
    v_saved public.shop_products%rowtype;
begin
    if (select auth.uid()) is null
       or not exists (
            select 1 from public.shop_admins as a
            where a.user_id = (select auth.uid())
       ) then
        raise exception 'Admin access required' using errcode = '42501';
    end if;

    if pg_catalog.length(v_name) not between 1 and 160
       or p_category is null or p_category not in ('valorant', 'pubg', 'mobile', 'account')
       or p_price is null or p_price not between 1 and 500000
       or pg_catalog.length(v_tag) > 32 or pg_catalog.length(v_description) > 2000
       or v_image_file !~ '^[A-Za-z0-9_-]+[.](png|jpg|jpeg|webp)$'
       or p_active is null then
        raise exception 'Invalid product data' using errcode = '22023';
    end if;

    if p_product_id is null then
        if p_expected_revision is not null then
            raise exception 'Product version conflict' using errcode = '40001';
        end if;

        insert into public.shop_products (name, category, price, tag, description, image_file, active)
        values (v_name, p_category, p_price, v_tag, v_description, v_image_file, p_active)
        returning * into v_saved;
    else
        select p.* into v_before
        from public.shop_products as p
        where p.id = p_product_id
        for update;

        if not found then
            raise exception 'Product not found' using errcode = '22023';
        end if;
        if p_expected_revision is null or v_before.revision <> p_expected_revision then
            raise exception 'Product version conflict' using errcode = '40001';
        end if;

        update public.shop_products as p
           set name = v_name,
               category = p_category,
               price = p_price,
               tag = v_tag,
               description = v_description,
               image_file = v_image_file,
               active = p_active,
               revision = p.revision + 1
         where p.id = p_product_id
        returning p.* into v_saved;
    end if;

    insert into public.shop_admin_audit_log (admin_user_id, action, details)
    values (
        (select auth.uid()),
        case when p_product_id is null then 'create_product' else 'update_product' end,
        pg_catalog.jsonb_build_object(
            'product_id', v_saved.id,
            'before', pg_catalog.to_jsonb(v_before),
            'after', pg_catalog.to_jsonb(v_saved)
        )
    );

    return pg_catalog.jsonb_build_object('id', v_saved.id, 'revision', v_saved.revision);
end;
$$;

revoke all on function public.admin_dashboard_summary() from public, anon, authenticated;
revoke all on function public.admin_list_orders(text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_get_order_detail(uuid) from public, anon, authenticated;
revoke all on function public.admin_cancel_pending_order(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_confirm_order_payment(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.admin_list_products(text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.admin_save_product(integer, text, text, integer, text, text, text, boolean, integer) from public, anon, authenticated;
grant usage on schema public to authenticated;
grant execute on function public.admin_dashboard_summary() to authenticated;
grant execute on function public.admin_list_orders(text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_order_detail(uuid) to authenticated;
grant execute on function public.admin_cancel_pending_order(uuid, text) to authenticated;
grant execute on function public.admin_confirm_order_payment(uuid, text, boolean) to authenticated;
grant execute on function public.admin_list_products(text, text, integer, integer) to authenticated;
grant execute on function public.admin_save_product(integer, text, text, integer, text, text, text, boolean, integer) to authenticated;

commit;
