import express from 'express';
import session from 'express-session';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as jose from 'jose';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readSecret(name, fallbackEnv) {
  const secretPath = `/run/secrets/${name}`;
  if (fs.existsSync(secretPath)) return fs.readFileSync(secretPath, 'utf8').trim();
  if (fallbackEnv && process.env[fallbackEnv]) return process.env[fallbackEnv];
  throw new Error(`Missing secret: ${name}`);
}

const REALM_ISSUER = 'https://auth.house-of-trae.com/realms/stratus-digital';
const CLIENT_ID = 'stratus-portal';
const CLIENT_SECRET = readSecret('kc_client_secret');
const SESSION_SECRET = readSecret('session_secret');
const REDIRECT_URI = 'https://stratus-digital.com/portal/callback';
const POST_LOGOUT_REDIRECT = 'https://stratus-digital.com/';

const AUTH_ENDPOINT = `${REALM_ISSUER}/protocol/openid-connect/auth`;
const TOKEN_ENDPOINT = `${REALM_ISSUER}/protocol/openid-connect/token`;
const LOGOUT_ENDPOINT = `${REALM_ISSUER}/protocol/openid-connect/logout`;
const JWKS = jose.createRemoteJWKSet(new URL(`${REALM_ISSUER}/protocol/openid-connect/certs`));

// slug -> { name, url } — must match the portal_access values set on Keycloak users in this realm.
// "all" grants a user every site below (used for House of Trae staff accounts).
const SITES = {
  stratusdigital: { name: 'Stratus Digital', url: 'https://stratus-digital.com' },
  discreetelite: { name: 'Discreet Elite', url: 'https://discreet-elite.uk' },
  emeraldmarkets: { name: 'Emerald Markets', url: 'https://emerald-markets.net' },
  rubyosiris: { name: 'Ruby Osiris', url: 'https://rubyosiris.com' },
  evilrabbitart: { name: 'Evil Rabbit Art', url: 'https://evilrabbitart.com' },
  dicksonsupplies: { name: 'Dickson Supplies', url: 'https://dickson-supplies.com' },
};

async function checkSite(url) {
  const started = Date.now();
  try {
    const res = await fetch(url, { method: 'GET', redirect: 'follow', signal: AbortSignal.timeout(5000) });
    return { up: res.status < 400, status: res.status, ms: Date.now() - started };
  } catch (err) {
    return { up: false, status: null, ms: Date.now() - started, error: err.name === 'TimeoutError' ? 'timeout' : 'unreachable' };
  }
}

function sitesForUser(portalAccess) {
  const grants = (portalAccess || '').split(',').map((s) => s.trim()).filter(Boolean);
  if (grants.includes('all')) return Object.entries(SITES);
  return Object.entries(SITES).filter(([slug]) => grants.includes(slug));
}

const app = express();
app.set('trust proxy', 1);
app.use(session({
  secret: SESSION_SECRET,
  name: 'sd_portal_sid',
  resave: false,
  saveUninitialized: false,
  cookie: { secure: true, httpOnly: true, sameSite: 'lax', maxAge: 1000 * 60 * 60 * 4 },
}));

app.use(express.static(path.join(__dirname, 'public')));

const PAGE_HEAD = `<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Manrope:wght@600;700;800&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root { --sky:#EDEFF2; --sky-2:#E1E5EA; --slate:#2B3440; --slate-2:#1D242D; --ink:#14181D; --ink-soft:#4B5563;
    --paper:#F7F8F9; --line:#C9D0D8; --break:#3E7CB1; --break-soft:#DCE7F0; --sun:#E8A34C; --good:#2E9E5B; --bad:#C4453B; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--sky); color:var(--ink); font-family:'Inter',-apple-system,sans-serif; line-height:1.6; }
  h1,h2,.brand { font-family:'Manrope','Inter',sans-serif; letter-spacing:-0.01em; margin:0; }
  a { color: var(--break); }
  .wrap { max-width: 880px; margin: 0 auto; padding: 0 32px; }
  header.bar { background: var(--slate-2); padding: 22px 0; }
  header.bar .wrap { display:flex; align-items:center; justify-content:space-between; }
  header.bar .brand { color: var(--paper); font-size: 20px; }
  header.bar a.logout { color: #B7C0CC; font-size: 13px; }
  main { padding: 56px 0 80px; }
  .card { background: #fff; border: 1px solid var(--line); border-radius: 8px; padding: 32px; margin-bottom: 24px; }
  .center { text-align: center; }
  .btn { display: inline-block; background: var(--slate); color: #fff; padding: 13px 26px; border-radius: 4px; font-weight: 600; font-size: 14px; text-decoration: none; }
  .btn:hover { background: var(--slate-2); }
  .site-grid { display: grid; gap: 16px; }
  .site-row { display: flex; align-items: center; justify-content: space-between; padding: 18px 22px; border: 1px solid var(--line); border-radius: 6px; background: #fff; }
  .site-row .name { font-weight: 600; }
  .site-row .url { color: var(--ink-soft); font-size: 13px; }
  .badge { font-size: 12px; padding: 4px 10px; border-radius: 20px; font-weight: 600; }
  .badge.up { background: #E4F5EA; color: var(--good); }
  .badge.down { background: #FBEAE8; color: var(--bad); }
  .meta { color: var(--ink-soft); font-size: 12.5px; margin-top: 2px; }
  .view-link { font-size: 13px; margin-left: 18px; white-space: nowrap; }
</style>`;

app.get('/portal', async (req, res) => {
  if (!req.session.user) {
    res.send(`<!DOCTYPE html><html lang="en"><head><title>Client Login — Stratus Digital</title>${PAGE_HEAD}</head><body>
      <header class="bar"><div class="wrap"><a href="/" class="brand">Stratus Digital</a></div></header>
      <main><div class="wrap card center">
        <h1>Client Portal</h1>
        <p style="color:var(--ink-soft); margin: 16px 0 28px;">Log in to check the status of your site and reach us directly.</p>
        <a class="btn" href="/portal/login">Log In</a>
      </div></main>
    </body></html>`);
    return;
  }

  const entries = sitesForUser(req.session.user.portalAccess);
  const results = await Promise.all(entries.map(async ([slug, site]) => [slug, site, await checkSite(site.url)]));

  const rows = results.map(([slug, site, r]) => `
    <div class="site-row">
      <div>
        <div class="name">${site.name}</div>
        <div class="url">${site.url}</div>
        <div class="meta">${r.up ? `HTTP ${r.status} · ${r.ms}ms` : `unreachable${r.error ? ' — ' + r.error : ''}`}</div>
      </div>
      <div style="display:flex; align-items:center;">
        <span class="badge ${r.up ? 'up' : 'down'}">${r.up ? 'Live' : 'Down'}</span>
        <a class="view-link" href="${site.url}" target="_blank" rel="noopener">View site &rarr;</a>
      </div>
    </div>`).join('');

  res.send(`<!DOCTYPE html><html lang="en"><head><title>Client Portal — Stratus Digital</title>${PAGE_HEAD}</head><body>
    <header class="bar"><div class="wrap">
      <a href="/" class="brand">Stratus Digital</a>
      <a class="logout" href="/portal/logout">Log out (${req.session.user.portalLabel || req.session.user.username})</a>
    </div></header>
    <main><div class="wrap">
      <h1 style="margin-bottom: 8px;">Your sites</h1>
      <p style="color:var(--ink-soft); margin-bottom: 32px;">Live status, checked just now.</p>
      <div class="site-grid">${rows || '<p style="color:var(--ink-soft);">No sites are linked to this account yet — contact Stratus Digital to have one added.</p>'}</div>
    </div></main>
  </body></html>`);
});

app.get('/portal/login', (req, res) => {
  const state = crypto.randomBytes(16).toString('hex');
  const nonce = crypto.randomBytes(16).toString('hex');
  req.session.oauthState = state;
  req.session.oauthNonce = nonce;
  const params = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: 'code',
    scope: 'openid',
    redirect_uri: REDIRECT_URI,
    state,
    nonce,
    // Bypasses this realm's default identity-provider-redirector (auto-forward to the
    // house-of-trae staff broker) so external clients land on stratus-digital's own local
    // login form instead of the internal SSO flow. See claude-md/identity-dns-email.md.
    kc_idp_hint: '',
  });
  res.redirect(`${AUTH_ENDPOINT}?${params.toString()}`);
});

app.get('/portal/callback', async (req, res) => {
  const { code, state, error } = req.query;
  if (error) return res.status(400).send(`Login failed: ${error}`);
  if (!code || !state || state !== req.session.oauthState) {
    return res.status(400).send('Login failed: invalid or expired login attempt. <a href="/portal/login">Try again</a>.');
  }

  try {
    const tokenRes = await fetch(TOKEN_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: REDIRECT_URI,
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
      }),
    });
    if (!tokenRes.ok) throw new Error(`token endpoint returned ${tokenRes.status}`);
    const tokens = await tokenRes.json();

    const { payload } = await jose.jwtVerify(tokens.id_token, JWKS, {
      issuer: REALM_ISSUER,
      audience: CLIENT_ID,
    });
    if (payload.nonce !== req.session.oauthNonce) throw new Error('nonce mismatch');

    req.session.user = {
      username: payload.preferred_username,
      portalAccess: payload.portal_access || '',
      portalLabel: payload.portal_label || '',
    };
    req.session.idToken = tokens.id_token;
    delete req.session.oauthState;
    delete req.session.oauthNonce;
    res.redirect('/portal');
  } catch (err) {
    console.error('OIDC callback failed:', err.message);
    res.status(400).send('Login failed: could not verify session with the identity provider. <a href="/portal/login">Try again</a>.');
  }
});

app.get('/portal/logout', (req, res) => {
  const idToken = req.session.idToken;
  req.session.destroy(() => {
    const params = new URLSearchParams({ post_logout_redirect_uri: POST_LOGOUT_REDIRECT });
    if (idToken) params.set('id_token_hint', idToken);
    res.redirect(`${LOGOUT_ENDPOINT}?${params.toString()}`);
  });
});

app.listen(3000, () => console.log('stratus-digital site listening on :3000'));
