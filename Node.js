const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const { sendMail } = require('./mailer'); // 引入我們測試成功的發信模組

const app = express();
app.use(cors());
app.use(express.json());

// ⚠️ 這裡的 Pool 設定請依照你實際的 GCP Cloud SQL 設定填寫
const pool = new Pool({
    user: process.env.DB_USER,
    host: process.env.DB_HOST,
    database: process.env.DB_NAME,
    password: process.env.DB_PASSWORD,
    port: 5432,
});

// ... (保留你之前寫的其他 API) ...

/**
 * API: 手動發送卡密並標記為已售出
 * 供 admin.html 呼叫
 */
app.post('/api/admin/dispatch-key', async (req, res) => {
    // 實務上這裡應該要加入驗證，確保呼叫這支 API 的人是管理員
    // 例如檢查 req.headers.authorization 中的 Token

    const { email, productName, keyId, keyCode } = req.body;

    if (!email || !productName || !keyId || !keyCode) {
        return res.status(400).json({ error: '缺少必要參數' });
    }

    const client = await pool.connect();

    try {
        await client.query('BEGIN'); // 開啟資料庫交易

        // 1. 再次確認這組卡密是否真的是「未使用」狀態 (防止重複發放)
        const keyCheck = await client.query(
            'SELECT is_used FROM product_keys WHERE id = $1 FOR UPDATE',
            [keyId]
        );

        if (keyCheck.rows.length === 0) {
            throw new Error('找不到該卡密');
        }
        if (keyCheck.rows[0].is_used) {
            throw new Error('該卡密已被標記為已使用，無法重複發放');
        }

        // 2. 寄送 Email (呼叫你的 mailer.js)
        const subject = `【凱欣商城】數位資產發貨通知：${productName}`;
        const bodyText = `感謝您的購買！\n\n您購買的商品：${productName}\n\n您的專屬卡密 / 授權碼如下：\n${keyCode}\n\n請妥善保管您的卡密，如有任何操作問題請聯繫客服。\n\n-- 凱欣商城 系統發送`;
        
        await sendMail(email, subject, bodyText);

        // 3. Email 寄送成功後，才將資料庫標記為「已使用」
        await client.query(
            'UPDATE product_keys SET is_used = true, updated_at = CURRENT_TIMESTAMP WHERE id = $1',
            [keyId]
        );

        await client.query('COMMIT'); // 交易成功，儲存變更
        
        res.status(200).json({ success: true, message: '郵件發送成功且卡密已註銷' });

    } catch (error) {
        await client.query('ROLLBACK'); // 若中途發生錯誤 (如發信失敗)，還原資料庫狀態
        console.error('發卡作業失敗:', error);
        res.status(500).json({ error: error.message || '伺服器內部錯誤' });
    } finally {
        client.release();
    }
});

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => console.log(`Backend running on port ${PORT}`));