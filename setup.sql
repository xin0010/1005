-- ============================================================
-- 凱欣商城 Supabase RLS Policy 設定
-- 使用方式：前往 Supabase Dashboard → SQL Editor → 貼上全部執行
-- ============================================================

-- ────────────────────────────────────────
-- 📦 products 商品表
-- ────────────────────────────────────────
-- 任何人（含訪客）可以讀取上架中商品
CREATE POLICY "Public can read active products"
ON products FOR SELECT
TO anon, authenticated
USING (true);

-- 已登入管理員可以新增商品
CREATE POLICY "Authenticated can insert products"
ON products FOR INSERT
TO authenticated
WITH CHECK (true);

-- 已登入管理員可以更新商品
CREATE POLICY "Authenticated can update products"
ON products FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

-- 已登入管理員可以刪除商品
CREATE POLICY "Authenticated can delete products"
ON products FOR DELETE
TO authenticated
USING (true);


-- ────────────────────────────────────────
-- 🔑 product_keys 卡密表
-- ────────────────────────────────────────
-- 已登入管理員可讀取卡密
CREATE POLICY "Authenticated can read product_keys"
ON product_keys FOR SELECT
TO authenticated
USING (true);

-- 已登入管理員可新增卡密
CREATE POLICY "Authenticated can insert product_keys"
ON product_keys FOR INSERT
TO authenticated
WITH CHECK (true);

-- 已登入管理員可刪除卡密
CREATE POLICY "Authenticated can delete product_keys"
ON product_keys FOR DELETE
TO authenticated
USING (true);


-- ────────────────────────────────────────
-- 🛒 orders 訂單表
-- ────────────────────────────────────────
-- 訪客（顧客下單）可以新增訂單
CREATE POLICY "Anon can insert orders"
ON orders FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- 已登入管理員可以讀取所有訂單
CREATE POLICY "Authenticated can read orders"
ON orders FOR SELECT
TO authenticated
USING (true);

-- 已登入管理員可以更新訂單狀態
CREATE POLICY "Authenticated can update orders"
ON orders FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

-- 已登入管理員可以刪除訂單
CREATE POLICY "Authenticated can delete orders"
ON orders FOR DELETE
TO authenticated
USING (true);


-- ────────────────────────────────────────
-- 🧾 order_items 訂單明細表
-- ────────────────────────────────────────
-- 訪客（顧客下單）可以新增訂單明細
CREATE POLICY "Anon can insert order_items"
ON order_items FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- 已登入管理員可以讀取所有訂單明細
CREATE POLICY "Authenticated can read order_items"
ON order_items FOR SELECT
TO authenticated
USING (true);


-- ────────────────────────────────────────
-- 📢 announcements 公告表
-- ────────────────────────────────────────
-- 任何人可以讀取公告
CREATE POLICY "Public can read announcements"
ON announcements FOR SELECT
TO anon, authenticated
USING (true);

-- 已登入管理員可以新增/更新公告
CREATE POLICY "Authenticated can upsert announcements"
ON announcements FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE POLICY "Authenticated can update announcements"
ON announcements FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);
