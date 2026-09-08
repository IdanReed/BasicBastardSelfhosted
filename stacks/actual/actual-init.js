// actual_init — headless first-run: POST /account/bootstrap, the endpoint the
// browser form calls. Fails closed on a missing/placeholder password;
// idempotent (already bootstrapped -> zero "CHANGE:" lines, exit 0).
//
// /account/bootstrap and /account/login share a 5-per-15-min limiter keyed by
// client IP, so there is deliberately no retry loop around the POSTs.
//
// Runs on the server image itself: node >= 18 global fetch, no deps.

'use strict';

const BASE = process.env.INIT_URL || 'http://actual:5006';
const PASSWORD = process.env.ACTUAL_INIT_PASSWORD;

function fail(msg) {
  console.error(`actual-init: FATAL: ${msg}`);
  process.exit(1);
}

// A changeme_ placeholder would be ACCEPTED by the server — a finance server
// whose password sits in git.
if (!PASSWORD) fail('ACTUAL_INIT_PASSWORD is empty or unset — refusing to bootstrap');
if (PASSWORD.startsWith('changeme_'))
  fail('ACTUAL_INIT_PASSWORD is still a changeme_ placeholder — refusing to bootstrap');

async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { 'Content-Type': 'application/json' },
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

async function main() {
  // needs-bootstrap is unauthenticated and NOT rate-limited, so polling it is
  // free — unlike the two POSTs below.
  let state;
  for (let i = 0; ; i++) {
    try {
      const r = await api('GET', '/account/needs-bootstrap');
      state = r.json?.data;
      if (state) break;
    } catch (e) {
      if (i >= 30) fail(`server unreachable at ${BASE}: ${e}`);
    }
    if (i >= 30) fail(`no usable /account/needs-bootstrap answer from ${BASE}`);
    await new Promise((r) => setTimeout(r, 2000));
  }

  if (state.bootstrapped) {
    console.log(
      'actual-init: already bootstrapped ' +
        `(loginMethod=${state.loginMethod}); nothing to do`,
    );
    return;
  }

  // NEVER add openId here — bootstrap refuses two methods at once
  // ("max-one-method-allowed"); OIDC is a separate step (see compose.yaml).
  const boot = await api('POST', '/account/bootstrap', { password: PASSWORD });
  if (boot.json?.status !== 'ok') {
    // A concurrent rerun bootstrapped between the check and the POST.
    if (boot.json?.reason === 'already-bootstrapped') {
      console.log('actual-init: lost a benign race — already bootstrapped; nothing to do');
      return;
    }
    fail(`bootstrap refused (HTTP ${boot.http}): ${JSON.stringify(boot.json)}`);
  }
  console.log('CHANGE: bootstrapped the server password');

  // Only on the run that bootstraps: afterwards the password's source of truth
  // is the database, so a stale ACTUAL_INIT_PASSWORD must not fail a rerun.
  const login = await api('POST', '/account/login', {
    loginMethod: 'password',
    password: PASSWORD,
  });
  if (login.json?.status !== 'ok' || !login.json?.data?.token)
    fail(`post-bootstrap login FAILED (HTTP ${login.http}): ${JSON.stringify(login.json)}`);
  console.log('actual-init: verified — login with the bootstrapped password returns a token');
}

main().catch((e) => fail(String(e)));
