<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Magento Hello World Shop</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            flex-direction: column;
        }
        .header {
            background: white;
            padding: 20px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        h1 {
            color: #333;
            text-align: center;
            margin-bottom: 10px;
        }
        .subtitle {
            text-align: center;
            color: #666;
            margin-bottom: 20px;
        }
        .products {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-top: 30px;
        }
        .product-card {
            background: white;
            border-radius: 10px;
            padding: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.3s ease;
        }
        .product-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 6px 12px rgba(0,0,0,0.15);
        }
        .product-name {
            font-size: 1.2em;
            color: #333;
            margin-bottom: 10px;
            font-weight: bold;
        }
        .product-price {
            color: #667eea;
            font-size: 1.5em;
            font-weight: bold;
            margin: 10px 0;
        }
        .product-description {
            color: #666;
            font-size: 0.9em;
            margin-bottom: 15px;
        }
        .buy-button {
            background: #667eea;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 1em;
            width: 100%;
            transition: background 0.3s ease;
        }
        .buy-button:hover {
            background: #764ba2;
        }
        .cart {
            position: fixed;
            top: 20px;
            right: 20px;
            background: white;
            padding: 15px 25px;
            border-radius: 50px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
            font-weight: bold;
            color: #667eea;
        }
        .info-banner {
            background: #fff3cd;
            border: 1px solid #ffc107;
            border-radius: 5px;
            padding: 15px;
            margin: 20px 0;
            text-align: center;
        }
        .cluster-info {
            background: #d1ecf1;
            border: 1px solid #0c5460;
            border-radius: 5px;
            padding: 15px;
            margin: 20px 0;
        }
        .cluster-info h3 {
            color: #0c5460;
            margin-bottom: 10px;
        }
        .cluster-info p {
            color: #0c5460;
            margin: 5px 0;
        }
    </style>
</head>
<body>
    <div class="cart" id="cart">🛒 Cart: <span id="cart-count">0</span> items</div>
    
    <div class="header">
        <div class="container">
            <h1>🛍️ Magento Hello World Shop</h1>
            <p class="subtitle">Your First Kubernetes-Deployed E-Commerce Experience</p>
        </div>
    </div>

    <div class="container">
        <div class="cluster-info">
            <h3>📊 Deployment Information</h3>
            <p><strong>Pod Name:</strong> <?php echo gethostname(); ?></p>
            <p><strong>PHP Version:</strong> <?php echo phpversion(); ?></p>
            <p><strong>Server Time:</strong> <?php echo date('Y-m-d H:i:s'); ?></p>
            <p><strong>Environment:</strong> Kubernetes Cluster (K3s)</p>
        </div>

        <div class="info-banner">
            <strong>✨ This is a demo Magento-style e-commerce application</strong><br>
            Running on Kubernetes with Blue/Green deployment capability
        </div>

        <div class="products">
            <div class="product-card">
                <div class="product-name">🎮 Gaming Laptop</div>
                <div class="product-price">$1,299.99</div>
                <div class="product-description">
                    High-performance gaming laptop with RGB keyboard and powerful GPU
                </div>
                <button class="buy-button" onclick="addToCart('Gaming Laptop')">Add to Cart</button>
            </div>

            <div class="product-card">
                <div class="product-name">📱 Smartphone Pro</div>
                <div class="product-price">$899.99</div>
                <div class="product-description">
                    Latest flagship smartphone with amazing camera and 5G support
                </div>
                <button class="buy-button" onclick="addToCart('Smartphone Pro')">Add to Cart</button>
            </div>

            <div class="product-card">
                <div class="product-name">🎧 Wireless Headphones</div>
                <div class="product-price">$299.99</div>
                <div class="product-description">
                    Premium noise-canceling headphones with 30-hour battery life
                </div>
                <button class="buy-button" onclick="addToCart('Wireless Headphones')">Add to Cart</button>
            </div>

            <div class="product-card">
                <div class="product-name">⌚ Smart Watch</div>
                <div class="product-price">$399.99</div>
                <div class="product-description">
                    Fitness tracking smartwatch with heart rate monitor and GPS
                </div>
                <button class="buy-button" onclick="addToCart('Smart Watch')">Add to Cart</button>
            </div>

            <div class="product-card">
                <div class="product-name">💻 Mechanical Keyboard</div>
                <div class="product-price">$149.99</div>
                <div class="product-description">
                    RGB mechanical keyboard with custom switches and programmable keys
                </div>
                <button class="buy-button" onclick="addToCart('Mechanical Keyboard')">Add to Cart</button>
            </div>

            <div class="product-card">
                <div class="product-name">🖱️ Gaming Mouse</div>
                <div class="product-price">$79.99</div>
                <div class="product-description">
                    Precision gaming mouse with 16000 DPI and customizable buttons
                </div>
                <button class="buy-button" onclick="addToCart('Gaming Mouse')">Add to Cart</button>
            </div>
        </div>
    </div>

    <script>
        let cartCount = 0;

        function addToCart(productName) {
            cartCount++;
            document.getElementById('cart-count').textContent = cartCount;
            
            // Show a simple notification
            const notification = document.createElement('div');
            notification.style.cssText = `
                position: fixed;
                top: 100px;
                right: 20px;
                background: #4CAF50;
                color: white;
                padding: 15px 25px;
                border-radius: 5px;
                box-shadow: 0 4px 12px rgba(0,0,0,0.2);
                z-index: 1000;
                animation: slideIn 0.3s ease;
            `;
            notification.textContent = `✓ ${productName} added to cart!`;
            document.body.appendChild(notification);
            
            setTimeout(() => {
                notification.remove();
            }, 2000);
        }
    </script>
</body>
</html>