const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const { sendMail } = require('./mailer'); 

const app = express();

// 啟用 CORS，允許你的前端網址呼叫 API (上線後建議把 origin 設為你的 Vercel 網址)
app.use(cors());
// 解析 JSON 格式的請求本體
app.use(express.json());

// ==========================================
// 資料庫連線設定 (PostgreSQL / Supabase)
// ==========================================
// ⚠️ 請確保你在執行環境中 (或 .env 檔案裡) 有設定這些變數
const pool = new Pool({
    user: process.env.DB_USER,
    host: process.env.DB_HOST,
    database: process.env.DB_NAME,
    password: process.env.DB_PASSWORD,
    port: process.env.DB_PORT || 5432,
    // 如果連線到 Supabase 等雲端資料庫，通常需要開啟 SSL
    // ssl: { rejectUnauthorized: false } 
});

// ==========================================
// API 路由
// ==========================================

/**
 * 測試 API 是否正常運作
 */
app.get('/api/health', (req, res) => {
    res.status(200).json({ status: 'ok', message: 'AXG Backend is running.' });
});

/**
 * API 1: 前台發送「信箱綁定驗證碼」
 * 接收信箱與前端生成的驗證碼，並寄出信件
 */
app.post('/api/send-verify-code', async (req, res) => {
    const { email, code } = req.body;

    if (!email || !code) {
        return res.status(400).json({ error: '缺少信箱或驗證碼參數' });
    }

    try {
        const subject = '【凱欣商城】SYSTEM_PORTAL 信箱綁定驗證碼';
        const bodyText = `您好，\n\n系統收到您的信箱綁定請求。\n您的 6 位數授權驗證碼為：[ ${code} ]\n\n請在頁面倒數結束前輸入此驗證碼以完成綁定。\n若非本人操作請直接忽略此信件。\n\n-- 凱欣商城 自動化系統發送`;
        
        // 呼叫 mailer.js 寄信
        await sendMail(email, subject, bodyText);
        
        res.status(200).json({ success: true, message: '驗證碼發送成功' });
    } catch (error) {
        console.error('發送驗證碼失敗:', error);
        res.status(500).json({ error: '伺服器發信失敗，請稍後再試' });
    }
});

/**
 * API 2: 後台手動發送卡密並標記為已售出
 * 驗證卡密狀態 -> 發信 -> 扣除庫存(標記使用)
 */
app.post('/api/admin/dispatch-key', async (req, res) => {
    const { email, productName, keyId, keyCode } = req.body;

    if (!email || !productName || !keyId || !keyCode) {
        return res.status(400).json({ error: '缺少必要參數' });
    }

    // 從連線池取得一個獨立的連線，準備進行交易 (Transaction)
    const client = await pool.connect();
    
    try {
        await client.query('BEGIN'); // 啟動交易防護

        // 1. 檢查卡密狀態，並使用 FOR UPDATE 鎖定這筆資料，防止併發操作
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

        // 2. 準備信件內容並寄發
        const subject = `【凱欣商城】數位資產發貨通知：${productName}`;
        const bodyText = `感謝您的購買！\n\n您購買的商品：${productName}\n\n您的專屬卡密 / 授權碼如下：\n${keyCode}\n\n請妥善保管您的卡密，如有任何操作問題請聯繫客服。\n\n-- 凱欣商城 系統發送`;
        
        await sendMail(email, subject, bodyText);

        // 3. 信件發送成功後，更新資料庫，將卡密標記為已售出
        await client.query(
            'UPDATE product_keys SET is_used = true, updated_at = CURRENT_TIMESTAMP WHERE id = $1', 
            [keyId]
        );
        
        await client.query('COMMIT'); // 提交交易，變更生效
        
        res.status(200).json({ success: true, message: '郵件發送成功且卡密已註銷' });
    } catch (error) {
        await client.query('ROLLBACK'); // 發生任何錯誤（如寄信失敗），復原資料庫狀態
        console.error('發卡作業失敗:', error);
        res.status(500).json({ error: error.message || '伺服器內部錯誤' });
    } finally {
        client.release(); // 釋放資料庫連線
    }
});

// ==========================================
// 啟動伺服器
// ==========================================
const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
    console.log(`🚀 Backend is running on port ${PORT}`);
});