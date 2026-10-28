// actual_init — headless first-run, then the OpenID switch.
//
//  1. Password: POST /account/bootstrap, the endpoint the browser form calls.
//     Fails closed on a missing/placeholder password.
//  2. OpenID: once a password exists, POST /openid/enable with an admin
//     session — what upstream's scripts/enable-openid.js does, over HTTP. The
//     ORDER is the safety property: with a password method on file, the first
//     OpenID login (which becomes the permanent server owner) must also enter
//     the server password, and the password stays the way in while Authentik
//     is down. The stored client is compared with the env on every run and
//     re-applied on drift, so a rotated client secret goes live with the
//     redeploy that carries it.
//
// Idempotent: a converged server logs zero "CHANGE:" lines, and needs no login
// and no traffic beyond the server itself.
//
// /account/bootstrap and /account/login share a 5-per-15-min limiter keyed by
// client IP (only failures count), so there is deliberately no retry loop
// around the POSTs.
//
// Runs on the server image itself: node >= 18 global fetch, and the image's
// own better-sqlite3 for the read-only drift check. Never prints a secret.

'use strict';

const BASE = process.env.INIT_URL || 'http://actual:5006';
const PASSWORD = process.env.ACTUAL_INIT_PASSWORD;
// The server's /data, mounted read-only (compose.yaml). Every write goes
// through the HTTP API.
const ACCOUNT_DB = process.env.ACCOUNT_DB || '/data/server-files/account.sqlite';

const OIDC = {
  discoveryURL: process.env.ACTUAL_OPENID_DISCOVERY_URL || '',
  client_id: process.env.ACTUAL_OPENID_CLIENT_ID || '',
  client_secret: process.env.ACTUAL_OPENID_CLIENT_SECRET || '',
  server_hostname: process.env.ACTUAL_OPENID_SERVER_HOSTNAME || '',
};

function fail(msg) {
  console.error(`actual-init: FATAL: ${msg}`);
  process.exit(1);
}

// A changeme_ placeholder would be ACCEPTED by the server — a finance server
// whose password sits in git.
if (!PASSWORD) fail('ACTUAL_INIT_PASSWORD is empty or unset — refusing to bootstrap');
if (PASSWORD.startsWith('changeme_'))
  fail('ACTUAL_INIT_PASSWORD is still a changeme_ placeholder — refusing to bootstrap');

async function api(method, path, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['x-actual-token'] = token;
  const res = await fetch(BASE + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json;
  try {
    json = await res.json();
  } catch {
    fail(`${method} ${path} returned HTTP ${res.status} with a non-JSON body`);
  }
  return { http: res.status, json };
}

// needs-bootstrap is unauthenticated and NOT rate-limited, so polling it is
// free — unlike the POSTs. `multiuser` is true exactly when OpenID is the
// active login method.
async function serverState() {
  for (let i = 0; ; i++) {
    try {
      const r = await api('GET', '/account/needs-bootstrap');
      if (r.json?.data) return r.json.data;
    } catch (e) {
      if (i >= 30) fail(`server unreachable at ${BASE}: ${e}`);
    }
    if (i >= 30) fail(`no usable /account/needs-bootstrap answer from ${BASE}`);
    await new Promise((r) => setTimeout(r, 2000));
  }
}

// Returns an admin session token when this run bootstrapped, else null.
async function ensurePassword() {
  const state = await serverState();
  if (state.bootstrapped) {
    console.log(`actual-init: already bootstrapped (loginMethod=${state.loginMethod})`);
    return null;
  }

  // NEVER add openId here — bootstrap refuses two methods at once
  // ("max-one-method-allowed"); OpenID is ensureOpenId's step.
  const boot = await api('POST', '/account/bootstrap', { password: PASSWORD });
  if (boot.json?.status !== 'ok') {
    // A concurrent rerun bootstrapped between the check and the POST.
    if (boot.json?.reason === 'already-bootstrapped') {
      console.log('actual-init: lost a benign race — already bootstrapped');
      return null;
    }
    fail(`bootstrap refused (HTTP ${boot.http}): ${JSON.stringify(boot.json)}`);
  }
  console.log('CHANGE: bootstrapped the server password');

  // Only on the run that bootstraps: afterwards the password's source of truth
  // is the database, so a stale ACTUAL_INIT_PASSWORD fails a rerun only when
  // the OpenID step needs a session.
  const login = await api('POST', '/account/login', {
    loginMethod: 'password',
    password: PASSWORD,
  });
  if (login.json?.status !== 'ok' || !login.json?.data?.token)
    fail(`post-bootstrap login FAILED (HTTP ${login.http}): ${JSON.stringify(login.json)}`);
  console.log('actual-init: verified — login with the bootstrapped password returns a token');
  return login.json.data.token;
}

// The client exactly as bootstrapOpenId stores it: the discovery URL lands in
// `issuer`.
function storedOpenIdClient() {
  let row;
  let db;
  try {
    const Database = require('/app/node_modules/better-sqlite3');
    db = new Database(ACCOUNT_DB, { readonly: true, fileMustExist: true });
    row = db.prepare("SELECT extra_data FROM auth WHERE method = 'openid' AND active = 1").get();
  } catch (e) {
    fail(`cannot read the stored OpenID client from ${ACCOUNT_DB}: ${e.message}`);
  } finally {
    db?.close();
  }
  if (!row) fail('the server reports OpenID active, but account.sqlite has no active openid row');
  try {
    return JSON.parse(row.extra_data);
  } catch {
    fail('the stored OpenID client is not JSON');
  }
}

// Unreachable or 5xx is Authentik being down: the password keeps working, so
// that is a WARN and exit 0, retried by the next deploy. Anything else wrong
// with the discovery answer is configuration, and fatal.
async function issuerAnswers(verb) {
  const skip = (why) => {
    console.log(
      `actual-init: WARN: OpenID NOT ${verb} — ${why}. Password login is ` +
        'unaffected; redeploy the stack once Authentik answers.',
    );
    return false;
  };
  let res;
  try {
    res = await fetch(OIDC.discoveryURL, { signal: AbortSignal.timeout(20000) });
  } catch (e) {
    return skip(`issuer unreachable (${e.cause?.code || e.name})`);
  }
  if (res.status >= 500) return skip(`issuer answered HTTP ${res.status}`);
  if (!res.ok)
    fail(`discovery returned HTTP ${res.status} for ${OIDC.discoveryURL} — wrong URL or slug?`);
  let meta;
  try {
    meta = await res.json();
  } catch {
    fail(`discovery at ${OIDC.discoveryURL} returned a non-JSON body`);
  }
  if (!meta?.authorization_endpoint || !meta?.token_endpoint)
    fail(`discovery at ${OIDC.discoveryURL} names no authorization/token endpoint`);
  return true;
}

async function ensureOpenId(token) {
  // Unset is the off switch: the login method is then left as it is.
  if (!OIDC.discoveryURL) {
    console.log('actual-init: ACTUAL_OPENID_DISCOVERY_URL unset — OpenID left as it is');
    return;
  }
  const required = {
    ACTUAL_OPENID_CLIENT_ID: OIDC.client_id,
    ACTUAL_OPENID_CLIENT_SECRET: OIDC.client_secret,
    ACTUAL_OPENID_SERVER_HOSTNAME: OIDC.server_hostname,
  };
  for (const [k, v] of Object.entries(required)) {
    if (!v) fail(`${k} is empty or unset — refusing to configure OpenID`);
    if (v.startsWith('changeme_')) fail(`${k} is still a changeme_ placeholder — refusing to configure OpenID`);
  }

  const want = {
    issuer: OIDC.discoveryURL,
    client_id: OIDC.client_id,
    client_secret: OIDC.client_secret,
    server_hostname: OIDC.server_hostname,
  };
  const state = await serverState();
  const hasPassword = (state.availableLoginMethods || []).some((m) => m.method === 'password');

  let verb = 'enabled';
  if (state.multiuser === true) {
    const stored = storedOpenIdClient();
    // Field NAMES only — the values include the client secret.
    const drift = Object.keys(want).filter((k) => stored[k] !== want[k]);
    if (drift.length === 0) {
      console.log('actual-init: OpenID active with the configured client; nothing to do');
      if (!hasPassword)
        console.log('actual-init: WARN: no password method on file — Authentik is the only way in');
      return;
    }
    console.log(`actual-init: stored OpenID client differs from the env in: ${drift.join(', ')}`);
    verb = 're-applied';
  }

  if (!(await issuerAnswers(verb))) return;

  if (!token) {
    const login = await api('POST', '/account/login', {
      loginMethod: 'password',
      password: PASSWORD,
    });
    if (login.json?.status !== 'ok' || !login.json?.data?.token)
      fail(
        `password login for the OpenID step FAILED (HTTP ${login.http}, ` +
          `${login.json?.reason}) — ACTUAL_INIT_PASSWORD no longer matches the ` +
          'server password (changed in the client?); put the current one in it and redeploy',
      );
    token = login.json.data.token;
  }

  // The server re-runs discovery itself, then replaces the openid row and
  // deletes every session (enableOpenID). authMethod is what upstream's own
  // env path stores alongside the rest.
  const openId = { ...OIDC, authMethod: 'openid' };
  const res = await api('POST', '/openid/enable', { openId }, token);
  if (res.json?.status !== 'ok')
    fail(`POST /openid/enable refused (HTTP ${res.http}): ${JSON.stringify(res.json)}`);

  const after = await serverState();
  if (after.multiuser !== true)
    fail('POST /openid/enable said ok, but OpenID is still not the active login method');
  console.log(`CHANGE: ${verb} OpenID (client ${OIDC.client_id}); every session was signed out`);
  if (verb === 'enabled')
    console.log(
      'actual-init: the FIRST OpenID login becomes the permanent server owner ' +
        '(and must also enter the server password) — make it idan',
    );
}

async function main() {
  const token = await ensurePassword();
  await ensureOpenId(token);
}

main().catch((e) => fail(String(e)));
