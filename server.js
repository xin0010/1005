/**
 * AXG 凱欣商店 - 企業級後端核心 API (Vercel 雲端特化版)
 */
const express = require('express');
const mysql = require('mysql2/promise');
const cors = require('cors');
const bcrypt = require('bcrypt');
const { v4: uuidv4 } = require('uuid');
const nodemailer = require('nodemailer');
const crypto = require('crypto');

// ==========================================
// Admin Token 驗證工具
// ==========================================
const ADMIN_SECRET = process.env.ADMIN_SECRET || 'axg-local-dev-fallback-secret';

function signAdminToken(payload) {
    const data = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const sig = crypto.createHmac('sha256', ADMIN_SECRET).update(data).digest('base64url');
    return `${data}.${sig}`;
}

function verifyAdminToken(token) {
    if (!token) return null;
    const parts = token.split('.');
    if (parts.length !== 2) return null;
    const [data, sig] = parts;
    const expectedSig = crypto.createHmac('sha256', ADMIN_SECRET).update(data).digest('base64url');
    if (sig !== expectedSig) return null;
    try {
        const payload = JSON.parse(Buffer.from(data, 'base64url').toString());
        if (payload.exp < Date.now()) return null;
        if (payload.role !== 'admin') return null;
        return payload;
    } catch { return null; }
}

function adminAuth(req, res, next) {
    const token = req.headers['x-admin-token'];
    if (!verifyAdminToken(token)) return res.status(401).json({ error: '未授權，請重新登入' });
    next();
}

const app = express();

app.use(cors({
    origin: [
        'https://axgshop888.com.tw',
        'https://www.axgshop888.com.tw',
        'http://localhost:3000'
    ],
    credentials: true
}));
app.use(express.json());

// ==========================================
// 💡 設定 Google 寄信機器人 (Nodemailer)
// ==========================================
const transporter = nodemailer.createTransport({
    service: 'gmail',
    auth: {
        user: 'yang20080221@gmail.com', // ⚠️ 請替換為你的 Gmail
        pass: 'mrevmstwduaxxjxc' // ⚠️ 請替換為你的 Gmail 應用程式密碼      
    }
});

// ==========================================
// 1. 資料庫連線池設定
// ==========================================
const pool = mysql.createPool({
    host: '34.81.99.227',
    user: 'axgshop200',
    password: 'axg-02210825A',
    database: 'axf',
    port: 3306,
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0
});

pool.getConnection()
    .then(async conn => {
        console.log('✅ 資料庫連線池建立成功 (Vercel 雲端特化版)！');
        
        try {
            await conn.query(`CREATE TABLE IF NOT EXISTS settings (id INT AUTO_INCREMENT PRIMARY KEY, setting_key VARCHAR(50) UNIQUE, setting_value TEXT)`);
            await conn.query(`INSERT IGNORE INTO settings (setting_key, setting_value) VALUES ('announcement', '歡迎來到 YEN！系統目前正常運作中。')`);
            await conn.query(`CREATE TABLE IF NOT EXISTS email_codes (email VARCHAR(255) PRIMARY KEY, code VARCHAR(10), expires_at DATETIME)`);
            await conn.query(`CREATE TABLE IF NOT EXISTS chat_messages (id INT AUTO_INCREMENT PRIMARY KEY, session_id VARCHAR(100) NOT NULL, user_email VARCHAR(255), sender VARCHAR(20) NOT NULL, message TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
            
            // 💡 核心新增：建立「卡密金庫」資料表
            await conn.query(`
                CREATE TABLE IF NOT EXISTS product_keys (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    product_id INT NOT NULL,
                    key_code VARCHAR(255) NOT NULL,
                    is_used BOOLEAN DEFAULT false,
                    order_id VARCHAR(50) DEFAULT NULL,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE KEY unique_key_per_product (product_id, key_code)
                )
            `);

            try { await conn.query(`ALTER TABLE products ADD COLUMN helper_status VARCHAR(20) DEFAULT 'normal'`); } catch (e) {}
            try { await conn.query(`ALTER TABLE products ADD COLUMN description TEXT DEFAULT NULL`); } catch (e) {}

            console.log('✅ 系統資料庫結構檢查完畢！');
        } catch (err) {
            console.error('⚠️ 資料庫初始化過程發生異常:', err.message);
        }
        conn.release();
    })
    .catch(err => console.error('❌ 資料庫連線失敗：', err.message));


// ==========================================
// 2. 客服對話 API
// ==========================================
app.post('/api/chat/send', async (req, res) => {
    const { session_id, user_email, sender, message } = req.body;
    if (!session_id || !message) return res.status(400).json({ error: '訊息格式錯誤' });
    try {
        await pool.query('INSERT INTO chat_messages (session_id, user_email, sender, message) VALUES (?, ?, ?, ?)', [session_id, user_email || 'Guest', sender, message]);
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: '發送失敗' }); }
});

app.get('/api/chat/messages/:session_id', async (req, res) => {
    try {
        const [rows] = await pool.query('SELECT * FROM chat_messages WHERE session_id = ? ORDER BY created_at ASC', [req.params.session_id]);
        res.json(rows);
    } catch (err) { res.status(500).json({ error: '獲取對話失敗' }); }
});

app.get('/api/admin/chat/sessions', adminAuth, async (req, res) => {
    try {
        const [rows] = await pool.query(`SELECT session_id, MAX(user_email) as user_email, MAX(created_at) as last_activity FROM chat_messages GROUP BY session_id ORDER BY last_activity DESC`);
        res.json(rows);
    } catch (err) { res.status(500).json({ error: '獲取列表失敗' }); }
});

// ==========================================
// 3. 帳號註冊與登入 API
// ==========================================
app.post('/api/auth/register', async (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ error: '請填寫所有欄位' });
    if (password.length < 6) return res.status(400).json({ error: '密碼至少需要6個字元' });
    try {
        const [existing] = await pool.query('SELECT id FROM users WHERE email = ?', [email]);
        if (existing.length > 0) return res.status(400).json({ error: '此信箱已被註冊' });
        const passwordHash = await bcrypt.hash(password, 10);
        const userId = uuidv4();
        await pool.query('INSERT INTO users (id, email, password_hash, role) VALUES (?, ?, ?, ?)', [userId, email, passwordHash, 'customer']);
        res.json({ success: true, message: '註冊成功' });
    } catch (err) { res.status(500).json({ error: '系統錯誤' }); }
});

app.post('/api/auth/login-user', async (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ error: '請填寫帳號與密碼' });
    try {
        const [users] = await pool.query('SELECT * FROM users WHERE email = ?', [email]);
        if (!users[0] || !(await bcrypt.compare(password, users[0].password_hash))) {
            return res.status(401).json({ error: '帳號或密碼錯誤' });
        }
        res.json({ success: true, email: users[0].email });
    } catch (err) { res.status(500).json({ error: '系統異常' }); }
});

// ==========================================
// 4. 信箱驗證 API (舊系統保留相容)
// ==========================================
app.post('/api/auth/send-code', async (req, res) => {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: '請提供接收郵箱' });
    const code = Math.floor(100000 + Math.random() * 900000).toString(); 
    const expiresAt = new Date(Date.now() + 10 * 60000); 
    try {
        await pool.query('INSERT INTO email_codes (email, code, expires_at) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE code = ?, expires_at = ?', [email, code, expiresAt, code, expiresAt]);
        await transporter.sendMail({
            from: '"YEN" <yang20080221@gmail.com>',
            to: email,
            subject: 'YEN - 您的專屬驗證碼',
            text: `您的驗證碼為：${code}\n請在 10 分鐘內返回 https://axgshop888.com.tw 完成綁定。`
        });
        res.json({ success: true, message: '驗證碼已發送' });
    } catch (err) { res.status(500).json({ error: '寄件失敗' }); }
});

app.post('/api/auth/verify-code', async (req, res) => {
    const { email, code } = req.body;
    try {
        const [rows] = await pool.query('SELECT * FROM email_codes WHERE email = ? AND code = ? AND expires_at > NOW()', [email, code]);
        if (rows.length > 0) {
            await pool.query('DELETE FROM email_codes WHERE email = ?', [email]); 
            res.json({ success: true });
        } else res.status(400).json({ error: '驗證碼錯誤或過期' });
    } catch (err) { res.status(500).json({ error: '驗證失敗' }); }
});

// ==========================================
// 4. 前台會員 API
// ==========================================
app.get('/api/user/orders', async (req, res) => {
    const { email } = req.query;
    if (!email) return res.status(400).json({ error: '請提供信箱' });
    try {
        const [rows] = await pool.query(
            `SELECT o.id as order_id, o.total_price, o.status, o.created_at
             FROM orders o JOIN users u ON o.user_id = u.id
             WHERE u.email = ? ORDER BY o.created_at DESC`,
            [email]
        );
        res.json(rows);
    } catch (err) { res.status(500).json({ error: '獲取失敗' }); }
});

app.put('/api/user/password', async (req, res) => {
    const { email, currentPassword, newPassword } = req.body;
    if (!email || !currentPassword || !newPassword) return res.status(400).json({ error: '請填寫所有欄位' });
    if (newPassword.length < 6) return res.status(400).json({ error: '新密碼至少需要6個字元' });
    try {
        const [users] = await pool.query('SELECT * FROM users WHERE email = ?', [email]);
        if (!users[0] || !(await bcrypt.compare(currentPassword, users[0].password_hash))) {
            return res.status(401).json({ error: '目前密碼錯誤' });
        }
        const newHash = await bcrypt.hash(newPassword, 10);
        await pool.query('UPDATE users SET password_hash = ? WHERE email = ?', [newHash, email]);
        res.json({ success: true, message: '密碼已更新' });
    } catch (err) { res.status(500).json({ error: '系統錯誤' }); }
});

// ==========================================
// 5. 前台商品與訂單 API
// ==========================================
app.get('/api/announcement', async (req, res) => {
    try {
        const [rows] = await pool.query("SELECT setting_value FROM settings WHERE setting_key = 'announcement'");
        res.json({ text: rows[0]?.setting_value || '' });
    } catch (err) { res.status(500).json({ error: '獲取公告失敗' }); }
});

app.get('/api/products', async (req, res) => {
    try {
        const [rows] = await pool.query("SELECT * FROM products WHERE status = 'active' AND stock > 0 ORDER BY id DESC");
        res.json(rows);
    } catch (err) { res.status(500).json({ error: `查詢錯誤: ${err.message}` }); }
});

// 💡 結帳邏輯更新：自動發卡
app.post('/api/orders/checkout', async (req, res) => {
    const { email, cartItems } = req.body;
    if (!email || !cartItems || cartItems.length === 0) return res.status(400).json({ error: '訂單資料不完整' });

    const conn = await pool.getConnection();
    try {
        await conn.beginTransaction(); 

        let [users] = await conn.query('SELECT id FROM users WHERE email = ?', [email]);
        let userId = users.length > 0 ? users[0].id : uuidv4();
        if (users.length === 0) {
            const randomPassword = await bcrypt.hash(uuidv4(), 10);
            await conn.query('INSERT INTO users (id, email, password_hash, role) VALUES (?, ?, ?, ?)', [userId, email, randomPassword, 'customer']);
        }

        let totalPrice = 0;
        for (let item of cartItems) {
            const [products] = await conn.query('SELECT price, stock FROM products WHERE id = ? FOR UPDATE', [item.id]);
            if (products.length === 0 || products[0].stock < item.quantity) throw new Error(`商品ID ${item.id} 庫存不足`);
            totalPrice += parseFloat(products[0].price) * item.quantity;
        }

        const now = new Date();
        const timeString = now.getFullYear().toString() + String(now.getMonth() + 1).padStart(2, '0') + String(now.getDate()).padStart(2, '0') + String(now.getHours()).padStart(2, '0') + String(now.getMinutes()).padStart(2, '0') + String(now.getSeconds()).padStart(2, '0');
        const randomNum = Math.floor(1000 + Math.random() * 9000); 
        const orderId = `AXG${timeString}${randomNum}`; 
        const virtualAccount = "808" + Math.floor(10000000000 + Math.random() * 90000000000); 
        
        await conn.query('INSERT INTO orders (id, user_id, total_price, status, virtual_account) VALUES (?, ?, ?, ?, ?)', [orderId, userId, totalPrice, 'pending', virtualAccount]);

        for (let item of cartItems) {
            const [products] = await conn.query('SELECT price FROM products WHERE id = ?', [item.id]);
            await conn.query('INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (?, ?, ?, ?)', [orderId, item.id, item.quantity, products[0].price]);
            
            // 💡 已移除自動取卡綁定邏輯，改為純手動發貨
            await conn.query('UPDATE products SET stock = stock - ? WHERE id = ?', [item.quantity, item.id]);
        }

        await conn.commit(); 
        res.status(201).json({ success: true, orderId, virtualAccount, totalPrice, message: '訂單建立成功' });
    } catch (err) {
        await conn.rollback(); 
        res.status(400).json({ error: err.message || '結帳失敗' });
    } finally { conn.release(); }
});

// ==========================================
// 5. 後台 API (包含卡密管理)
// ==========================================
app.post('/api/announcement', adminAuth, async (req, res) => {
    try {
        await pool.query("UPDATE settings SET setting_value = ? WHERE setting_key = 'announcement'", [req.body.text]);
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: '更新失敗' }); }
});

app.post('/api/auth/login', async (req, res) => {
    try {
        const [users] = await pool.query('SELECT * FROM users WHERE email = ?', [req.body.email]);
        if (!users[0] || !(await bcrypt.compare(req.body.password, users[0].password_hash))) return res.status(401).json({ error: '帳密錯誤' });
        const token = signAdminToken({ id: users[0].id, email: users[0].email, role: users[0].role, exp: Date.now() + 24 * 60 * 60 * 1000 });
        res.json({ success: true, token, user: { id: users[0].id, email: users[0].email, role: users[0].role } });
    } catch (err) { res.status(500).json({ error: '系統異常' }); }
});

app.get('/api/orders', adminAuth, async (req, res) => {
    try {
        const [rows] = await pool.query(`SELECT o.id as order_id, o.total_price, o.status, o.virtual_account, o.created_at, u.email FROM orders o JOIN users u ON o.user_id = u.id ORDER BY o.created_at DESC`);
        res.json(rows);
    } catch (err) { res.status(500).json({ error: '獲取失敗' }); }
});

app.put('/api/orders/:id/status', adminAuth, async (req, res) => {
    try {
        await pool.query('UPDATE orders SET status = ? WHERE id = ?', [req.body.status, req.params.id]);
        res.json({ message: '更新成功' });
    } catch (err) { res.status(500).json({ error: '更新失敗' }); }
});

app.delete('/api/orders/:id', adminAuth, async (req, res) => {
    const { id } = req.params;
    const conn = await pool.getConnection();
    try {
        await conn.beginTransaction(); 
        // 💡 移除自動釋放卡密邏輯
        await conn.query('DELETE FROM order_items WHERE order_id = ?', [id]);
        await conn.query('DELETE FROM orders WHERE id = ?', [id]);
        await conn.commit();
        res.json({ message: '訂單已成功刪除' });
    } catch (err) {
        await conn.rollback();
        res.status(500).json({ error: '刪除失敗' });
    } finally { conn.release(); }
});

app.get('/api/admin/products', adminAuth, async (req, res) => {
    try {
        const [rows] = await pool.query("SELECT * FROM products ORDER BY id DESC");
        res.json(rows);
    } catch (err) { res.status(500).json({ error: '獲取失敗' }); }
});

app.post('/api/products', adminAuth, async (req, res) => {
    const { category, name, price, stock, status, helper_status, description } = req.body;
    try {
        const [result] = await pool.execute(`INSERT INTO products (category, name, price, stock, status, helper_status, description) VALUES (?, ?, ?, ?, ?, ?, ?)`, [category, name, price, stock || 0, status || 'active', helper_status || 'normal', description || '']);
        res.status(201).json({ id: result.insertId });
    } catch (err) { res.status(500).json({ error: '新增失敗' }); }
});

app.put('/api/products/:id', adminAuth, async (req, res) => {
    const { category, name, price, stock, status, helper_status, description } = req.body;
    try {
        await pool.execute(`UPDATE products SET category = ?, name = ?, price = ?, stock = ?, status = ?, helper_status = ?, description = ? WHERE id = ?`, [category, name, price, stock, status, helper_status || 'normal', description || '', req.params.id]);
        res.json({ message: '更新成功' });
    } catch (err) { res.status(500).json({ error: '更新失敗' }); }
});

app.delete('/api/products/:id', adminAuth, async (req, res) => {
    try {
        await pool.execute(`UPDATE products SET status = 'inactive' WHERE id = ?`, [req.params.id]);
        res.json({ message: '下架成功' });
    } catch (err) { res.status(500).json({ error: '下架失敗' }); }
});

app.delete('/api/products/:id/permanent', adminAuth, async (req, res) => {
    const conn = await pool.getConnection();
    try {
        await conn.beginTransaction();
        await conn.execute('DELETE FROM product_keys WHERE product_id = ?', [req.params.id]);
        await conn.execute('DELETE FROM order_items WHERE product_id = ?', [req.params.id]);
        await conn.execute('DELETE FROM products WHERE id = ?', [req.params.id]);
        await conn.commit();
        res.json({ message: '商品已永久刪除' });
    } catch (err) {
        await conn.rollback();
        res.status(500).json({ error: '刪除失敗' });
    } finally { conn.release(); }
});

// ==========================================
// 💡 全新模組：卡密金庫 API
// ==========================================

// 獲取某商品的卡密列表
app.get('/api/admin/products/:id/keys', adminAuth, async (req, res) => {
    try {
        const [rows] = await pool.query('SELECT * FROM product_keys WHERE product_id = ? ORDER BY is_used ASC, created_at DESC', [req.params.id]);
        res.json(rows);
    } catch (err) { res.status(500).json({ error: '獲取卡密失敗' }); }
});

// 批量新增卡密
app.post('/api/admin/products/:id/keys', adminAuth, async (req, res) => {
    const { id } = req.params;
    const { keys } = req.body; // 陣列
    if (!keys || !keys.length) return res.status(400).json({ error: '請提供卡密' });

    const conn = await pool.getConnection();
    try {
        await conn.beginTransaction();
        for (let k of keys) {
            await conn.query('INSERT IGNORE INTO product_keys (product_id, key_code) VALUES (?, ?)', [id, k.trim()]);
        }
        // 💡 移除自動同步更新庫存，讓庫存保持手動管理
        await conn.commit();
        res.json({ success: true, message: '卡密新增成功' });
    } catch (err) {
        await conn.rollback();
        res.status(500).json({ error: '新增卡密失敗' });
    } finally { conn.release(); }
});

// 刪除卡密
app.delete('/api/admin/keys/:id', adminAuth, async (req, res) => {
    const conn = await pool.getConnection();
    try {
        await conn.beginTransaction();
        await conn.query('DELETE FROM product_keys WHERE id = ?', [req.params.id]);
        // 💡 移除自動同步更新庫存
        await conn.commit();
        res.json({ success: true });
    } catch (err) {
        await conn.rollback();
        res.status(500).json({ error: '刪除失敗' });
    } finally { conn.release(); }
});

const PORT = process.env.PORT || 3000;
if (process.env.NODE_ENV !== 'production') {
    app.listen(PORT, () => {
        console.log(`🚀 API 伺服器已啟動於：http://localhost:${PORT}`);
    });
}
module.exports = app;
