// actual_init — headless first-run for the Actual sync server.
//
// Actual's first run is a browser form; no env var, no CLI. The form POSTs
// /account/bootstrap, an unauthenticated endpoint that works exactly once
// (v26.9.0 src/app-account.js: refuses "already-bootstrapped" once the auth
// table is non-empty). This drives that endpoint from inside the project
// network, so the server is never up-and-passwordless.
//
// House rules (the beszel-init/tandoor-init conventions):
//   - fails CLOSED: empty or changeme_ password -> exit 1 before any HTTP.
//   - idempotent: already bootstrapped -> zero "CHANGE:" lines, exit 0.
//   - verifies its own work: after bootstrapping, log in once and require a
//     token back ("bootstrap ok" alone is also true of a mangled password).
//
// ⚠ The verify login runs ONLY on the run that bootstraps. Afterwards the
// password's source of truth is the DATABASE (in-UI change is legitimate),
// so a stale ACTUAL_INIT_PASSWORD is expected, not an error — a rerun must
// not fail on it.
//
// ⚠ Rate limit: /account/bootstrap and /account/login share a 5-per-15-min
// limiter keyed by client IP. This script spends at most 2 of those, once
// ever; keep it that way (no retry loop around the POSTs).
//
// Runs on the server image itself: node >= 18 global fetch, no deps.

'use strict';

const BASE = process.env.INIT_URL || 'http://actual:5006';
const PASSWORD = process.env.ACTUAL_INIT_PASSWORD;

function fail(msg) {
  console.error(`actual-init: FATAL: ${msg}`);
  process.exit(1);
}

// Fail closed. Empty would be rejected server-side anyway (isValidPassword
// refuses '' — verified); a changeme_ placeholder would be ACCEPTED — the
// trap: a finance server whose password sits in a public git repo.
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
  // depends_on service_healthy already gates on the server answering, but a
  // short GET loop keeps a healthcheck/ratelimit edge from becoming a failed
  // deploy. needs-bootstrap is unauthenticated and NOT rate-limited.
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

  // Body shape verified against bootstrap(): {password} enables exactly the
  // password method. NEVER add openId here — bootstrap refuses two methods
  // at once ("max-one-method-allowed"), and the OIDC path is a deliberate
  // separate step (see compose.yaml).
  const boot = await api('POST', '/account/bootstrap', { password: PASSWORD });
  if (boot.json?.status !== 'ok') {
    // Benign race: a concurrent rerun of this script bootstrapped between
    // the check and the POST.
    if (boot.json?.reason === 'already-bootstrapped') {
      console.log('actual-init: lost a benign race — already bootstrapped; nothing to do');
      return;
    }
    fail(`bootstrap refused (HTTP ${boot.http}): ${JSON.stringify(boot.json)}`);
  }
  console.log('CHANGE: bootstrapped the server password');

  // Verify: a real login must yield a token.
  const login = await api('POST', '/account/login', {
    loginMethod: 'password',
    password: PASSWORD,
  });
  if (login.json?.status !== 'ok' || !login.json?.data?.token)
    fail(`post-bootstrap login FAILED (HTTP ${login.http}): ${JSON.stringify(login.json)}`);
  console.log('actual-init: verified — login with the bootstrapped password returns a token');
}

main().catch((e) => fail(String(e)));
