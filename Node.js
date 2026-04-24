const express = require('express');
const { Pool } = require('pg'); // PostgreSQL 客戶端
const crypto = require('crypto');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

// 設定 GCP Cloud SQL 連線 (未來部署時使用環境變數)
const pool = new Pool({
    user: process.env.DB_USER,
    host: process.env.DB_HOST,
    database: process.env.DB_NAME,
    password: process.env.DB_PASSWORD,
    port: 5432,
});

/**
 * API: 建立訂單與取得 ATM 虛擬帳號
 * 安全性優化：金額由後端重新計算，不信任前端傳來的總價。
 */
app.post('/api/checkout', async (req, res) => {
    const { email, cartItems } = req.body; // 前端只需傳 [{ productId: '...', quantity: 1 }]

    if (!email || !cartItems || cartItems.length === 0) {
        return res.status(400).json({ error: '無效的訂單資料' });
    }

    const client = await pool.connect();

    try {
        // 開啟資料庫交易 (Transaction)，確保庫存扣除與訂單建立同時成功或同時失敗
        await client.query('BEGIN');

        let calculatedTotal = 0;
        const orderItemsToInsert = [];

        // 1. 驗證商品、計算總價、檢查庫存
        for (const item of cartItems) {
            const productRes = await client.query(
                'SELECT name, price, stock FROM products WHERE id = $1 AND status = $2 FOR UPDATE', 
                [item.productId, 'active'] // FOR UPDATE 防止併發時庫存超賣 (Race Condition)
            );

            if (productRes.rows.length === 0) {
                throw new Error(`商品 ${item.productId} 不存在或已下架`);
            }

            const product = productRes.rows[0];

            if (product.stock < item.quantity) {
                throw new Error(`商品 ${product.name} 庫存不足`);
            }

            // 計算精準金額
            calculatedTotal += parseFloat(product.price) * item.quantity;

            orderItemsToInsert.push({
                productId: item.productId,
                name: product.name,
                price: product.price,
                quantity: item.quantity
            });

            // 預扣庫存
            await client.query(
                'UPDATE products SET stock = stock - $1 WHERE id = $2',
                [item.quantity, item.productId]
            );
        }

        // 2. 模擬串接第三方金流 (如綠界) 取得虛擬帳號
        // 實務上這裡會是呼叫金流商的 API： const ECPayRes = await ecpay.createOrder(...)
        const orderNumber = 'ORD-' + crypto.randomInt(100000, 999999).toString();
        const virtualAccount = '812' + crypto.randomInt(10000000000, 99999999999).toString(); // 模擬台新銀行虛擬帳號
        const paymentDeadline = new Date(Date.now() + 24 * 60 * 60 * 1000); // 24小時後

        // 3. 寫入訂單主表
        const orderRes = await client.query(
            `INSERT INTO orders (order_number, user_email, total_amount, status, virtual_account, payment_deadline) 
             VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
            [orderNumber, email, calculatedTotal, 'pending', virtualAccount, paymentDeadline]
        );
        const newOrderId = orderRes.rows[0].id;

        // 4. 寫入訂單項目表
        for (const item of orderItemsToInsert) {
            await client.query(
                `INSERT INTO order_items (order_id, product_id, product_name, unit_price, quantity) 
                 VALUES ($1, $2, $3, $4, $5)`,
                [newOrderId, item.productId, item.name, item.price, item.quantity]
            );
        }

        // 提交交易
        await client.query('COMMIT');

        // 回傳安全的訂單資訊給前端顯示
        res.status(200).json({
            success: true,
            orderData: {
                orderNumber,
                totalAmount: calculatedTotal,
                virtualAccount,
                paymentDeadline,
                items: orderItemsToInsert
            }
        });

    } catch (error) {
        // 發生錯誤，回滾資料庫狀態，庫存復原
        await client.query('ROLLBACK');
        console.error('結帳失敗:', error);
        res.status(500).json({ error: error.message || '伺服器內部錯誤' });
    } finally {
        client.release();
    }
});

/**
 * API: 金流商 Webhook 回調 (ATM 匯款成功通知)
 * 這支 API 是給 ECPay/NewebPay 呼叫的，不是給前端呼叫的。
 */
app.post('/webhook/payment-success', async (req, res) => {
    // 1. 驗證金流商的 CheckMacValue (防偽造)
    // 2. 更新訂單狀態 UPDATE orders SET status = 'paid' WHERE virtual_account = req.body.vAccount
    // 3. 從 product_keys 表撈取對應數量的卡密，發送 Email 給客戶
    res.send('1|OK'); // 回應金流商
});

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => console.log(`Backend running on port ${PORT}`));