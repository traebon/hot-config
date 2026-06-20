import express from 'express';
import session from 'express-session';
import connectPg from 'connect-pg-simple';
import pg from 'pg';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.json());

function readSecret(key) {
  const file = process.env[key];
  if (file && fs.existsSync(file)) return fs.readFileSync(file, 'utf8').trim();
  return process.env[key.replace('_FILE', '')] || '';
}

const DB_PASSWORD    = readSecret('DB_PASSWORD_FILE');
const ANTHROPIC_KEY  = readSecret('ANTHROPIC_API_KEY_FILE');
const SESSION_SECRET = readSecret('SESSION_SECRET_FILE') || 'fallback-secret';
const CLIENT_SECRET  = readSecret('OIDC_CLIENT_SECRET_FILE');
const ADMIN_EMAILS   = (process.env.ADMIN_EMAILS || '').split(',').map(e => e.trim().toLowerCase());
const KEYCLOAK_URL   = process.env.KEYCLOAK_URL || 'https://auth.house-of-trae.com';
const REALM          = process.env.KEYCLOAK_REALM || 'house-of-trae';
const CLIENT_ID      = process.env.OIDC_CLIENT_ID || 'namegen';
const BASE_URL       = process.env.BASE_URL || 'http://sn-infra.spangled-atlas.ts.net:8010';
const ADMIN_PATH     = process.env.ADMIN_PATH || '/mgmt-a7x92k';

const pool = new pg.Pool({
  host: process.env.DB_HOST || 'db',
  port: 5432,
  database: process.env.DB_NAME || 'namegen',
  user: process.env.DB_USER || 'namegen',
  password: DB_PASSWORD,
  keepAlive: true,
  keepAliveInitialDelayMillis: 10000,
  idleTimeoutMillis: 60000,
  connectionTimeoutMillis: 5000,
});

const PgSession = connectPg(session);
app.use(session({
  store: new PgSession({ pool, tableName: 'sessions', createTableIfMissing: true }),
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, httpOnly: true, maxAge: 8 * 60 * 60 * 1000 }
}));

function randSlug(n = 16) {
  const c = 'abcdefghijkmnpqrstuvwxyz23456789';
  return Array.from({ length: n }, () => c[Math.floor(Math.random() * c.length)]).join('');
}

function isAdmin(req) {
  return ADMIN_EMAILS.includes((req.session.user?.email || '').toLowerCase());
}

function isLoggedIn(req) {
  return !!req.session.user;
}

let oidcMeta = null;

async function getOidcMeta() {
  if (oidcMeta) return oidcMeta;
  const url = `${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`OIDC discovery failed: ${r.status}`);
  oidcMeta = await r.json();
  return oidcMeta;
}

app.get('/auth/login', async (req, res) => {
  try {
    const meta = await getOidcMeta();
    const state = randSlug(16);
    const nonce = randSlug(16);
    req.session.state = state;
    req.session.nonce = nonce;
    req.session.returnTo = req.query.returnTo || '/';
    const params = new URLSearchParams({
      response_type: 'code',
      client_id: CLIENT_ID,
      redirect_uri: `${BASE_URL}/auth/callback`,
      scope: 'openid email profile',
      state,
      nonce,
    });
    res.redirect(`${meta.authorization_endpoint}?${params}`);
  } catch (e) {
    console.error('Login error:', e.message);
    res.status(500).send('Login unavailable: ' + e.message);
  }
});

app.get('/auth/callback', async (req, res) => {
  try {
    const { code, state } = req.query;
    if (state !== req.session.state) return res.status(400).send('State mismatch');
    const meta = await getOidcMeta();
    const body = new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: `${BASE_URL}/auth/callback`,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    });
    const tokenRes = await fetch(meta.token_endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!tokenRes.ok) {
      const err = await tokenRes.text();
      throw new Error(`Token exchange failed: ${err}`);
    }
    const tokens = await tokenRes.json();
    const payload = JSON.parse(Buffer.from(tokens.id_token.split('.')[1], 'base64url').toString());
    req.session.user = {
      email: payload.email,
      name: payload.name || payload.preferred_username,
      sub: payload.sub,
    };
    delete req.session.state;
    delete req.session.nonce;
    res.redirect(req.session.returnTo || '/');
  } catch (e) {
    console.error('Callback error:', e.message);
    res.status(500).send('Authentication failed: ' + e.message);
  }
});

app.get('/auth/logout', (req, res) => {
  req.session.destroy();
  res.redirect(`${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/logout?client_id=${CLIENT_ID}&post_logout_redirect_uri=${encodeURIComponent(BASE_URL)}`);
});

app.get('/api/me', (req, res) => {
  if (!isLoggedIn(req)) return res.json({ logged_in: false });
  res.json({ logged_in: true, email: req.session.user.email, name: req.session.user.name, is_admin: isAdmin(req) });
});

app.post('/api/generate', async (req, res) => {
  const { name } = req.body;
  if (!name || name.trim().length < 2) return res.status(400).json({ error: 'Name required' });

  const existing = await pool.query(
    'SELECT pseudo FROM mappings WHERE lower(real) = lower($1)', [name.trim()]
  );
  if (existing.rows.length) {
    return res.json({ result: existing.rows[0].pseudo });
  }

  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 20,
        system: 'Generate a completely different realistic full name from the one given. Different first name and surname. Reply with ONLY the name, nothing else.',
        messages: [{ role: 'user', content: name.trim() }]
      })
    });
    const data = await r.json();
    if (!data.content?.[0]?.text) throw new Error('Bad API response');
    const result = data.content[0].text.trim();

    if (isLoggedIn(req)) {
      await pool.query(
        'INSERT INTO mappings (real, pseudo, created_by) VALUES ($1,$2,$3) ON CONFLICT (real) DO NOTHING',
        [name.trim(), result, req.session.user.email]
      ).catch(() => {});
    }

    res.json({ result });
  } catch (e) {
    console.error('Generate error:', e.message);
    res.status(500).json({ error: 'Generation failed' });
  }
});

app.get(ADMIN_PATH, (req, res) => {
  if (!isAdmin(req)) {
    return res.redirect(`/auth/login?returnTo=${encodeURIComponent(ADMIN_PATH)}`);
  }
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

app.get('/api/admin/mappings', async (req, res) => {
  if (!isAdmin(req)) return res.status(403).json({ error: 'Forbidden' });
  const result = await pool.query('SELECT id, real, pseudo, created_by, created_at FROM mappings ORDER BY created_at DESC');
  res.json(result.rows);
});

app.delete('/api/admin/mappings/:id', async (req, res) => {
  if (!isAdmin(req)) return res.status(403).json({ error: 'Forbidden' });
  await pool.query('DELETE FROM mappings WHERE id = $1', [req.params.id]);
  res.json({ ok: true });
});

app.get('/api/admin/export', async (req, res) => {
  if (!isAdmin(req)) return res.status(403).json({ error: 'Forbidden' });
  const result = await pool.query('SELECT real, pseudo, created_by, created_at FROM mappings ORDER BY created_at DESC');
  const csv = 'Real Name,Pseudonym,Added By,Date\n' +
    result.rows.map(r => `"${r.real}","${r.pseudo}","${r.created_by}","${String(r.created_at).split('T')[0]}"`).join('\n');
  res.setHeader('Content-Type', 'text/csv');
  res.setHeader('Content-Disposition', `attachment; filename="mappings-${new Date().toISOString().split('T')[0]}.csv"`);
  res.send(csv);
});

app.use(express.static(path.join(__dirname, 'public')));

const PORT = process.env.PORT || 8010;
app.listen(PORT, async () => {
  try {
    await getOidcMeta();
    console.log('OIDC discovery successful');
  } catch (e) {
    console.warn('OIDC discovery failed on startup:', e.message);
  }
  console.log(`namegen running on port ${PORT}`);
});
