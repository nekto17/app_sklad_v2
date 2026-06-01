#!/bin/bash

# Скрипт автоматического развертывания WMS "Вектор" на Ubuntu Server 20.04 / 22.04 LTS
# Запуск: curl -s https://yourdomain.com/deploy.sh | bash

set -e

# Цветовая палитра для логов
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}>>> Начало автоматического развертывания складской системы 'Вектор'...${NC}"

# 1. Обновление ОС
echo -e "${GREEN}>>> 1. Обновление пакетов операционной системы...${NC}"
sudo apt update && sudo apt upgrade -y

# 2. Установка PostgreSQL СУБД
echo -e "${GREEN}>>> 2. Установка и настройка PostgreSQL...${NC}"
sudo apt install postgresql postgresql-contrib -y

# Запуск и включение службы PostgreSQL в автозагрузку
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Создание базы данных и пользователя
echo -e "${GREEN}>>> Настройка базы данных PostgreSQL...${NC}"
sudo -i -u postgres psql -c "CREATE DATABASE vector_warehouse;" || true
sudo -i -u postgres psql -c "CREATE USER vector_user WITH PASSWORD 'VectorSecurePass2026';" || true
sudo -i -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE vector_warehouse TO vector_user;" || true

# Создание таблиц БД
sudo -i -u postgres psql -d vector_warehouse -c "
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    username VARCHAR(50) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL CHECK (role IN ('Admin', 'Manager')),
    email VARCHAR(100) UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS items (
    id SERIAL PRIMARY KEY,
    sku VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    category_id INT REFERENCES categories(id) ON DELETE SET NULL,
    unit VARCHAR(10) DEFAULT 'шт',
    min_stock INT DEFAULT 10 CHECK (min_stock >= 0)
);

CREATE TABLE IF NOT EXISTS warehouses (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL,
    address VARCHAR(255) NOT NULL
);

CREATE TABLE IF NOT EXISTS stock_balances (
    id SERIAL PRIMARY KEY,
    item_id INT REFERENCES items(id) ON DELETE CASCADE,
    warehouse_id INT REFERENCES warehouses(id) ON DELETE CASCADE,
    balance INT DEFAULT 0 CHECK (balance >= 0),
    UNIQUE(item_id, warehouse_id)
);

CREATE TABLE IF NOT EXISTS inventory_logs (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    op_type VARCHAR(20) NOT NULL CHECK (op_type IN ('Поступление', 'Отгрузка', 'Перемещение', 'Списание')),
    item_id INT REFERENCES items(id) ON DELETE CASCADE,
    qty INT NOT NULL CHECK (qty > 0),
    price DECIMAL(10, 2) DEFAULT 0.00,
    warehouse_id INT REFERENCES warehouses(id) ON DELETE CASCADE,
    source_warehouse_id INT REFERENCES warehouses(id) ON DELETE SET NULL,
    counterparty VARCHAR(255),
    user_name VARCHAR(150) NOT NULL
);

-- Индексы для ускорения работы
CREATE INDEX IF NOT EXISTS idx_items_sku ON items(sku);
CREATE INDEX IF NOT EXISTS idx_stock_balances_item_warehouse ON stock_balances(item_id, warehouse_id);
" || true

# Вставка дефолтных пользователей (пароли: admin/admin, manager1/manager1)
sudo -i -u postgres psql -d vector_warehouse -c "
INSERT INTO users (name, username, password, role, email) 
VALUES ('Александр Иванов', 'admin', 'admin', 'Admin', 'admin@vector-sklad.ru')
ON CONFLICT (username) DO NOTHING;

INSERT INTO users (name, username, password, role, email) 
VALUES ('Мария Смирнова', 'manager1', 'manager1', 'Manager', 'smirnova@vector-sklad.ru')
ON CONFLICT (username) DO NOTHING;
" || true

# 3. Установка Node.js (LTS v18) и утилит сборки
echo -e "${GREEN}>>> 3. Установка Node.js & npm...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install nodejs git build-essential -y

# 4. Подготовка директорий приложения
echo -e "${GREEN}>>> 4. Подготовка директорий приложения...${NC}"
sudo mkdir -p /var/www/vector-wms/public
sudo chown -R $USER:$USER /var/www/vector-wms
cd /var/www/vector-wms

# Генерация структуры проекта
if [ ! -f "package.json" ]; then
  echo -e "${GREEN}>>> Инициализация npm проекта...${NC}"
  npm init -y
  npm install express pg dotenv cors
fi

# 5. Создание production-ready файла server.js (Решение вашей ошибки!)
echo -e "${GREEN}>>> Создание бэкенд сервера (server.js)...${NC}"
cat <<'EOF' > server.js
const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
const path = require('path');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json());

const pool = new Pool({
  connectionString: process.env.DATABASE_URL
});

// Проверка подключения к БД
pool.connect((err, client, release) => {
  if (err) {
    return console.error('Ошибка подключения к PostgreSQL:', err.stack);
  }
  console.log('Успешное подключение к PostgreSQL');
  release();
});

// Раздача статического фронтенда
app.use(express.static(path.join(__dirname, 'public')));

// Эндпоинт авторизации (упрощенная сверка по открытому паролю для примера)
app.post('/api/auth/login', async (req, res) => {
  const { username, password } = req.body;
  try {
    const result = await pool.query('SELECT id, name, username, role, email, password FROM users WHERE username = $1', [username]);
    if (result.rows.length === 0) {
      return res.status(401).json({ success: false, error: 'Пользователь не найден' });
    }
    const user = result.rows[0];
    if (user.password !== password) {
      return res.status(401).json({ success: false, error: 'Неверный пароль' });
    }
    delete user.password;
    res.json({ success: true, user });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// API-эндпоинт для проведения транзакционной складской операции
app.post('/api/inventory/operation', async (req, res) => {
  const { op_type, item_id, qty, price, warehouse_id, source_warehouse_id, counterparty, user_name } = req.body;
  
  if (!op_type || !item_id || !qty || qty <= 0 || !warehouse_id || !user_name) {
    return res.status(400).json({ success: false, error: 'Заполнены не все обязательные параметры' });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE');

    // Проверка наличия товара
    const itemCheck = await client.query('SELECT * FROM items WHERE id = $1 FOR SHARE', [item_id]);
    if (itemCheck.rows.length === 0) {
      throw new Error('Товар не найден в номенклатурном справочнике');
    }

    if (op_type === 'Поступление') {
      await client.query(`
        INSERT INTO stock_balances (item_id, warehouse_id, balance)
        VALUES ($1, $2, $3)
        ON CONFLICT (item_id, warehouse_id)
        DO UPDATE SET balance = stock_balances.balance + EXCLUDED.balance
      `, [item_id, warehouse_id, qty]);
    } 
    
    else if (op_type === 'Отгрузка' || op_type === 'Списание') {
      const balanceCheck = await client.query(
        'SELECT balance FROM stock_balances WHERE item_id = $1 AND warehouse_id = $2 FOR UPDATE',
        [item_id, warehouse_id]
      );
      const currentBalance = balanceCheck.rows.length > 0 ? balanceCheck.rows[0].balance : 0;
      if (currentBalance < qty) {
        throw new Error(`Недостаточно товара на складе для списания. Доступно: ${currentBalance}`);
      }
      await client.query(
        'UPDATE stock_balances SET balance = balance - $1 WHERE item_id = $2 AND warehouse_id = $3',
        [qty, item_id, warehouse_id]
      );
    } 
    
    else if (op_type === 'Перемещение') {
      if (!source_warehouse_id) {
        throw new Error('Не указан склад-источник для перемещения');
      }
      const sourceCheck = await client.query(
        'SELECT balance FROM stock_balances WHERE item_id = $1 AND warehouse_id = $2 FOR UPDATE',
        [item_id, source_warehouse_id]
      );
      const sourceBalance = sourceCheck.rows.length > 0 ? sourceCheck.rows[0].balance : 0;
      if (sourceBalance < qty) {
        throw new Error(`Недостаточно товара на складе-источнике. Доступно: ${sourceBalance}`);
      }
      await client.query(
        'UPDATE stock_balances SET balance = balance - $1 WHERE item_id = $2 AND warehouse_id = $3',
        [qty, item_id, source_warehouse_id]
      );
      await client.query(`
        INSERT INTO stock_balances (item_id, warehouse_id, balance)
        VALUES ($1, $2, $3)
        ON CONFLICT (item_id, warehouse_id)
        DO UPDATE SET balance = stock_balances.balance + EXCLUDED.balance
      `, [item_id, warehouse_id, qty]);
    }

    // Запись лога в историю
    await client.query(`
      INSERT INTO inventory_logs (op_type, item_id, qty, price, warehouse_id, source_warehouse_id, counterparty, user_name)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    `, [op_type, item_id, qty, price || 0, warehouse_id, source_warehouse_id || null, counterparty, user_name]);

    await client.query('COMMIT');
    res.json({ success: true, message: 'Операция успешно зарегистрирована' });
  } catch (error) {
    await client.query('ROLLBACK');
    res.status(400).json({ success: false, error: error.message });
  } finally {
    client.release();
  }
});

// Роутинг остальных статических страниц под SPA
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

const PORT = process.env.PORT || 5000;
app.listen(PORT, () => {
  console.log(`Сервер WMS запущен на порту ${PORT}`);
});
EOF

# 6. Копирование SPA фронтенда в статический каталог Nginx
echo -e "${GREEN}>>> Создание статического HTML фронтенда...${NC}"
# Если у нас уже есть сгенерированный index.html в текущей сессии Canvas, мы скопируем его содержимое.
# Ниже мы генерируем минимальный файл-заглушку, который при реальном развертывании заменяется на созданный React-код.
cat <<'EOF' > public/index.html
<!-- Здесь будет находиться React SPA-код вашего приложения (скопированный из Canvas) -->
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Вектор WMS — Загрузка...</title>
</head>
<body>
    <div id="root">Пожалуйста, скопируйте финальный index.html код из Canvas в директорию /var/www/vector-wms/public/index.html</div>
</body>
</html>
EOF

# 7. Создание конфигурационного файла окружения .env
echo -e "${GREEN}>>> 7. Запись системного окружения .env...${NC}"
cat <<EOT > .env
PORT=5000
DATABASE_URL=postgresql://vector_user:VectorSecurePass2026@localhost:5432/vector_warehouse
JWT_SECRET=VectorWmsSecretKeyJWT2026
NODE_ENV=production
EOT

# 8. Установка PM2 для фонового запуска Node.js
echo -e "${GREEN}>>> 8. Настройка менеджера процессов PM2...${NC}"
sudo npm install pm2 -g
pm2 start server.js --name "vector-backend" || pm2 restart "vector-backend"
pm2 save
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u $USER --hp /home/$USER

# 9. Настройка Nginx в качестве Reverse Proxy
echo -e "${GREEN}>>> 9. Установка и настройка веб-сервера Nginx...${NC}"
sudo apt install nginx -y

# Создание конфигурационного файла Nginx
sudo tee /etc/nginx/sites-available/vector <<'EOF'
server {
    listen 80;
    server_name _; # Сюда можно вписать доменное имя вашего сервера

    location / {
        root /var/www/vector-wms/public;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location /api {
        proxy_pass http://localhost:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
EOF

# Активация конфигурации Nginx
sudo ln (без -sf) /etc/nginx/sites-available/vector /etc/nginx/sites-enabled/ 2>/dev/null || sudo ln -sf /etc/nginx/sites-available/vector /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx

# 10. Настройка Firewall (UFW)
echo -e "${GREEN}>>> 10. Настройка сетевого экрана...${NC}"
sudo ufw allow 'Nginx Full'
sudo ufw allow OpenSSH
echo "y" | sudo ufw enable

echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN} Складская система ВЕКТОР успешно установлена и запущена! ${NC}"
echo -e "${GREEN} Приложение доступно по IP-адресу вашего сервера.         ${NC}"
echo -e "${GREEN} Скопируйте React-код из Canvas в /var/www/vector-wms/public/index.html ${NC}"
echo -e "${GREEN}=================================================================${NC}"