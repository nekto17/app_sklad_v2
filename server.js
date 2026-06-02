const express = require('express');
const router = express.Router();
const bcrypt = require('bcrypt'); // Для безопасного хэширования
const { Pool } = require('pg');

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

// Middleware для проверки JWT и роли Admin
function requireAdmin(req, res, next) {
  if (!req.user) {
    return res.status(401).json({ success: false, error: 'Требуется авторизация' });
  }
  if (req.user.role !== 'Admin') {
    return res.status(403).json({ success: false, error: 'Доступ запрещен. Требуются права Администратора' });
  }
  next();
}

/**
 * Создание сотрудника (доступно только Admin)
 * POST /api/users
 */
router.post('/users', requireAdmin, async (req, res) => {
  const { name, username, email, role, password } = req.body;

  if (!username || !password || !role) {
    return res.status(400).json({ success: false, error: 'Не все обязательные поля заполнены' });
  }

  try {
    const saltRounds = 10;
    const hashedPassword = await bcrypt.hash(password, saltRounds);

    const newUser = await pool.query(
      `INSERT INTO users (name, username, email, role, password) 
       VALUES ($1, $2, $3, $4, $5) RETURNING id, username, role`,
      [name, username, email, role, hashedPassword]
    );

    res.status(201).json({ success: true, user: newUser.rows[0] });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

/**
 * Редактирование сотрудника (доступно только Admin)
 * PUT /api/users/:id
 */
router.put('/users/:id', requireAdmin, async (req, res) => {
  const { id } = req.params;
  const { name, username, email, role, password } = req.body;

  try {
    let updateQuery = `UPDATE users SET name=$1, username=$2, email=$3, role=$4`;
    let params = [name, username, email, role];

    if (password) {
      const hashedPassword = await bcrypt.hash(password, 10);
      updateQuery += `, password=$5 WHERE id=$6 RETURNING id, username, role`;
      params.push(hashedPassword, id);
    } else {
      updateQuery += ` WHERE id=$5 RETURNING id, username, role`;
      params.push(id);
    }

    const updatedUser = await pool.query(updateQuery, params);
    res.json({ success: true, user: updatedUser.rows[0] });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});