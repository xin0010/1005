/**
 * AXG 凱欣商店 - 企業級資料庫初始化腳本 (MySQL)
 * 包含：密碼雜湊(bcrypt)、關聯式資料表(Foreign Keys)、交易一致性設計
 * * 執行方式： node db_setup.js
 */
const mysql = require('mysql2/promise');
const bcrypt = require('bcrypt');
const { v4: uuidv4 } = require('uuid');

// GCP 資料庫連線設定 (沿用你原本的設定)
const dbConfig = {
    host: '34.81.99.227',
    user: 'axgshop200',
    password: 'axg-02210825A',
    database: 'axf',
    port: 3306
};

// 初始商品清單
const initialProducts = [
    { category: 'PUBG', name: 'IOS-月卡', price: 1035.00, stock: 999 },
    { category: 'PUBG', name: '安卓-月卡', price: 1100.00, stock: 999 },
    { category: '傳說對決', name: 'ios月卡', price: 1070.00, stock: 50 },
    { category: '三角洲行動', name: '安卓單雷-月卡', price: 1300.00, stock: 30 },
    { category: 'IOS證書', name: '保固40天證書', price: 200.00, stock: 999 }
];

async function setupDatabase() {
    console.log('⏳ 正在連線至 GCP Cloud SQL...');
    let connection;

    try {
        connection = await mysql.createConnection(dbConfig);
        console.log('✅ 連線成功！準備重置並建立企業級資料表...\n');

        // 1. 關閉外鍵檢查，以便安全地刪除舊表
        await connection.execute('SET FOREIGN_KEY_CHECKS = 0');
        await connection.execute('DROP TABLE IF EXISTS order_items, orders, products, users');
        await connection.execute('SET FOREIGN_KEY_CHECKS = 1');
        console.log('🧹 舊有資料表已清空。');

        // ==========================================
        // 2. 建立資料表 (Table Creation)
        // ==========================================
        
        // A. 會員表 (Users) - 密碼嚴格加密
        await connection.execute(`
            CREATE TABLE users (
                id VARCHAR(36) PRIMARY KEY COMMENT 'UUID',
                email VARCHAR(255) UNIQUE NOT NULL,
                password_hash VARCHAR(255) NOT NULL COMMENT 'Bcrypt加密密碼',
                role ENUM('admin', 'customer') DEFAULT 'customer',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        `);
        console.log('✔️ [users] 會員系統資料表準備就緒');

        // B. 商品表 (Products) - 增加庫存檢查防禦
        await connection.execute(`
            CREATE TABLE products (
                id INT AUTO_INCREMENT PRIMARY KEY,
                category VARCHAR(50) NOT NULL,
                name VARCHAR(100) NOT NULL,
                price DECIMAL(10, 2) NOT NULL,
                stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
                status ENUM('active', 'inactive') DEFAULT 'active',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        `);
        console.log('✔️ [products] 商品資料表準備就緒');

        // C. 訂單主表 (Orders) - 紀錄金流虛擬帳號
        await connection.execute(`
            CREATE TABLE orders (
                id VARCHAR(36) PRIMARY KEY COMMENT '訂單編號(UUID)',
                user_id VARCHAR(36) NOT NULL,
                total_price DECIMAL(10, 2) NOT NULL,
                status VARCHAR(50) DEFAULT 'pending' COMMENT 'pending/paid/cancelled',
                virtual_account VARCHAR(50) COMMENT 'ATM 虛擬帳號',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT
            )
        `);
        console.log('✔️ [orders] 訂單主資料表準備就緒');

        // D. 訂單明細表 (Order Items) - 鎖定結帳當下價格
        await connection.execute(`
            CREATE TABLE order_items (
                id INT AUTO_INCREMENT PRIMARY KEY,
                order_id VARCHAR(36) NOT NULL,
                product_id INT NOT NULL,
                quantity INT NOT NULL CHECK (quantity > 0),
                unit_price DECIMAL(10, 2) NOT NULL COMMENT '結帳當下的單價',
                FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
                FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT
            )
        `);
        console.log('✔️ [order_items] 訂單明細資料表準備就緒\n');

        // ==========================================
        // 3. 寫入初始測試資料 (Seeding)
        // ==========================================
        console.log('⏳ 正在寫入預設資料...');

        // 建立一組預設管理員帳號
        const adminId = uuidv4();
        const adminEmail = 'admin@axgshop.com';
        const plainPassword = 'admin'; // 登入用的明文密碼
        const saltRounds = 10;
        const hashedPassword = await bcrypt.hash(plainPassword, saltRounds); // 加密過程

        await connection.execute(
            'INSERT INTO users (id, email, password_hash, role) VALUES (?, ?, ?, ?)',
            [adminId, adminEmail, hashedPassword, 'admin']
        );
        console.log(`👤 預設管理員已建立 -> 帳號: ${adminEmail} | 密碼: ${plainPassword}`);

        // 寫入商品資料
        for (const p of initialProducts) {
            await connection.execute(
                'INSERT INTO products (category, name, price, stock) VALUES (?, ?, ?, ?)',
                [p.category, p.name, p.price, p.stock]
            );
        }
        console.log(`📦 已成功匯入 ${initialProducts.length} 筆商品。`);

        console.log('\n🎉 太棒了！企業級資料庫架構建置完成！');

    } catch (error) {
        console.error('\n❌ 執行過程中發生錯誤：', error);
    } finally {
        if (connection) {
            await connection.end();
            console.log('🔌 已關閉資料庫連線。');
        }
    }
}

// 執行腳本
setupDatabase();