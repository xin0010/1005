-- 1. 商品表 (Products)
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    price DECIMAL(10, 2) NOT NULL CHECK (price >= 0), -- 防止負數價格
    stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
    status VARCHAR(20) DEFAULT 'active',
    helper_status VARCHAR(20) DEFAULT 'normal',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. 會員表 (Users) - 擴充未來的會員系統
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. 訂單表 (Orders)
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_number VARCHAR(50) UNIQUE NOT NULL, -- 給客戶看的訂單編號 (例如: ORD-123456)
    user_email VARCHAR(255) NOT NULL,
    total_amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending', -- pending, paid, completed, cancelled
    virtual_account VARCHAR(50), -- 綁定的 ATM 虛擬帳號
    payment_deadline TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. 訂單項目表 (Order Items)
CREATE TABLE order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID REFERENCES orders(id) ON DELETE CASCADE,
    product_id UUID REFERENCES products(id),
    product_name VARCHAR(255) NOT NULL, -- 紀錄當下名稱，防止商品改名影響歷史訂單
    unit_price DECIMAL(10, 2) NOT NULL, -- 紀錄當下購買價格
    quantity INT NOT NULL CHECK (quantity > 0)
);

-- 建立索引以優化查詢速度
CREATE INDEX idx_orders_user_email ON orders(user_email);
CREATE INDEX idx_products_status ON products(status);