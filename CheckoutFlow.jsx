// 這是前端 React 元件中 submitOrder 函數的優化版本
// 應替換掉 index.html 中原有的 submitOrder

const submitOrder = async () => {
    if (!agreedToTerms) return;
    
    setIsCheckoutConfirmOpen(false); 
    setLoading(true); // 顯示載入動畫，防止重複點擊
    
    try {
        // ⚠️ 優化重點：前端不再傳送總價，只傳送商品 ID 與數量
        const payload = {
            email: userEmail,
            cartItems: cart.map(item => ({
                productId: item.id,
                quantity: item.quantity
            }))
        };

        // 呼叫我們自己寫的 Node.js 後端 API，而非直接寫入 Supabase
        const response = await fetch('https://your-cloud-run-api.a.run.app/api/checkout', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                // 未來可加入 Authorization: `Bearer ${token}` 驗證會員
            },
            body: JSON.stringify(payload)
        });

        const data = await response.json();

        if (!response.ok) {
            throw new Error(data.error || '結帳失敗');
        }

        // 後端建立訂單成功，回傳包含精準金額與虛擬帳號的資料
        setOrderSuccessData({ 
            orderId: data.orderData.orderNumber, 
            totalPrice: data.orderData.totalAmount, // 使用後端計算的金額
            virtualAccount: data.orderData.virtualAccount,
            items: data.orderData.items, 
            createdAt: new Date(data.orderData.paymentDeadline).getTime() - (24 * 60 * 60 * 1000)
        });
        
        setCart([]);
        setIsCartOpen(false);
        setCurrentView('success');
        window.scrollTo(0, 0);

    } catch (err) { 
        console.error(err);
        showAlert(`❌ 結帳失敗：${err.message}`, 'ERROR'); 
    } finally {
        setLoading(false);
    }
};