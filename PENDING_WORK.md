# Pending Work: Security & Best-Practice Gaps

A point-in-time audit of what's *missing* from the current GameHub setup -
not what's broken (nothing here is currently exploited or causing an
outage), but what a more mature version of this stack would have. Every
item below was checked against the actual running system (code read
directly, or verified live against `alaab.ai`/Cloud Run config), not
assumed from a generic checklist - each one says how it was confirmed.

Organized by theme, each theme roughly ordered worst-first. A prioritized
short-list is at the end.

---

## 1. Network exposure: should this be behind a VPN / API Gateway?

**Short answer: no VPN, but yes to a few things sitting in front of Cloud
Run.**

A VPN makes sense for *internal* services - admin tools, staff dashboards,
service-to-service traffic that should never be reachable from the public
internet. GameHub is a consumer-facing app that random people sign up
and play - it needs to be publicly reachable by definition, so putting it
behind a VPN would just break it for real users. That's not the right
tool here.

What *is* missing, and would be the right tool:

- **Cloud Armor (WAF + DDoS protection) in front of Cloud Run.** Right
  now `alaab.ai` is a direct Cloud Run domain mapping - Google's edge
  terminates TLS and forwards straight to the container, with no rules
  layer in between. Cloud Armor can do IP-based rate limiting, geo-
  blocking, and basic WAF rule sets (SQLi/XSS signature blocking, mostly
  redundant here since the backend uses parameterized queries throughout,
  but still a real layer for the WebSocket endpoints and anything future
  code adds) before a request ever reaches the container. This is the
  actual "gateway" the app is missing - not a VPN.
- **API Gateway product (Apigee / Cloud Endpoints)** - probably
  overkill for the current surface area (9 REST-ish endpoints + 4 WS
  endpoints, single client family). The main things an API gateway would
  buy - centralized rate limiting, request validation, API key
  management - are more cheaply solved directly (see §4) given there's
  no third-party API consumer story here. Worth revisiting only if
  GameHub ever exposes an API to external developers.
- **Rate limiting at the edge** (Cloud Armor, or even just a
  `slowapi`/in-app limiter - see §4) is the single highest-value network-
  layer addition and doesn't exist in any form today.

## 2. Authentication & session security

- **Session cookie is missing the `Secure` attribute.**
  `backend/auth_routes.py` sets the cookie with `httponly=True,
  samesite="lax"` but no `secure=True` (verified by reading the
  `set_cookie(...)` call directly - Starlette defaults `secure` to
  `False` when unset). In practice everything is served over HTTPS today
  via the Cloud Run domain mapping, so this isn't exploitable *right
  now*, but the cookie itself doesn't enforce that - if anything ever
  regresses (a misconfigured redirect, a future HTTP listener), the
  session cookie would happily ride over plaintext. One-line fix:
  `secure=True` on the `set_cookie()` call.
- **No CSRF token; relying on `SameSite=Lax` alone.** Lax blocks
  cross-site POST via a background `fetch()`/form auto-submit, which
  covers most of the actual attack surface here, but it's the weaker of
  the two SameSite settings and isn't a substitute for a real CSRF token
  on state-changing endpoints (`/api/auth/login`, `/logout`, any future
  "delete my account" or "change email" endpoint). Low urgency given the
  current endpoint list, but worth adding before anything more
  destructive gets built behind this auth.
- **Cross-Site WebSocket Hijacking (CSWSH) - no `Origin` header check on
  any of the 4 WebSocket endpoints.** This is the one I'd actually call a
  real gap, not just theoretical: `game.py`, `connect4.py`, `ludo.py`,
  and `court_piece.py` all authenticate a WS connection purely via
  `websocket.cookies.get(SESSION_COOKIE)` - confirmed by reading each
  `websocket_endpoint()`. Browsers do **not** apply the Same-Origin
  Policy to the WebSocket handshake the way they do to `fetch()`/XHR, and
  `SameSite=Lax` cookie behavior on WS upgrade requests is inconsistent
  across browsers - meaning a malicious site could plausibly open
  `new WebSocket("wss://alaab.ai/ws?intent=random")` from a logged-in
  user's browser and have it succeed, riding their session cookie. Fix:
  validate the `Origin` header against an allowlist (`https://alaab.ai`)
  in each WS handler before accepting the connection.
- **No account lockout / no CAPTCHA / no rate limiting on login.**
  Verified live: 5 rapid wrong-password attempts against
  `/api/auth/login` all returned `200` with no throttling or backoff.
  Password hashing (bcrypt) makes each individual guess slow, but
  there's nothing stopping a distributed brute-force attempt at scale.
- **Account enumeration via `/api/auth/signup`.** The endpoint returns a
  distinct `"taken"` error when the email is already registered
  (confirmed by reading `auth_routes.signup()`) - so anyone can check
  whether a given email has a GameHub account just by attempting to sign
  up with it. (`forgot-password` and `resend-verification` both already
  do this correctly - same `ok()` response whether or not the account
  exists - `signup` is the one inconsistent endpoint.)
- **Session tokens are long-lived (7 days) with no revocation
  mechanism.** `SESSION_MAX_AGE = 60 * 60 * 24 * 7` in `config.py`. A
  stolen/leaked cookie is valid for a full week with no server-side way
  to invalidate it early (the signed cookie is stateless - there's no
  session table to delete a row from). Fine for a game app's risk
  profile, but worth knowing this is the tradeoff: no "log out all other
  devices" feature is even possible without adding a session-id
  allowlist/denylist in the DB.

## 3. Abuse prevention / rate limiting

Nothing in this whole category exists today - confirmed by reading every
route file, there is no throttling library, no `slowapi`, no
per-IP/per-account counters anywhere in `backend/`.

- **Email-sending endpoints are wide open**: `/api/auth/forgot-password`
  and `/api/auth/resend-verification` will happily fire an email on every
  single request, unauthenticated, with no cap. Someone could email-bomb
  an arbitrary address (using it as the `email` field) or exhaust the
  Gmail App Password's sending quota/reputation with a simple loop.
- **No per-connection or per-account cap on concurrent WebSocket
  connections or games.** A single account (or a single bot script that
  never logs in - wait, it does need a session, but a single account
  script) could open many `intent=random` connections in a loop and
  create/abandon many `games` dict entries, since there's no cap on
  concurrent private-game creation per account and no cleanup timer for
  abandoned lobbies beyond what happens on disconnect.
- **No general request-rate limiting** on any endpoint, authenticated or
  not.

Cheapest realistic fix: `slowapi` (Starlette/FastAPI-native, Redis-optional
- can run in-memory single-instance, which is actually fine here since
`maxScale=1`) on the auth and email-sending endpoints specifically.

## 4. Mobile-specific gaps

- **Session cookies are stored in plain `SharedPreferences`, not
  encrypted.** Confirmed: `mobile/pubspec.yaml` has no
  `flutter_secure_storage` (or equivalent) dependency, and
  `session_store.dart` uses `shared_preferences` directly for every
  account's cookie. On a non-rooted device this is sandboxed per-app and
  reasonably safe in practice, but it's not using the platform Keystore/
  Keychain the way a security-conscious app would, and it's a multi-
  account store - one compromised backup/root exposes every account
  that's ever logged in on that device, not just the active one.
- **No certificate pinning.** The app trusts whatever the OS trust store
  says is a valid cert for `alaab.ai`. Reasonable default, but means a
  device with a malicious CA installed (MDM abuse, some malware
  families) could MITM the app's traffic.
- **Debug logging (`debugPrint('GameHub sync: ...')`) includes full
  response bodies** in `api_client.dart` - only fires in debug builds
  (`debugPrint` is a no-op in release), so not a production risk, but
  worth double-checking nothing sensitive (tokens, other users' data)
  ever ends up in a body dump if this pattern gets copied into new code.
- **No app attestation (Play Integrity API).** The backend can't tell a
  request/WS connection came from the real, unmodified app vs. a
  scripted client hitting the same endpoints directly - not necessarily
  worth solving today given the risk profile (it's a game, not a
  payments app), but worth naming since "the mobile app is a trusted
  client" isn't actually enforced anywhere server-side.

## 5. Availability & scalability

This section is less "security hole," more "the architecture has a load-
bearing constraint that isn't written down anywhere obvious until now."

- **`maxScale=1` is a real single point of failure, and it's load-
  bearing, not incidental.** Confirmed via `gcloud run services describe`:
  `autoscaling.knative.dev/maxScale: '1'`. This exists *because* each
  game module (`game.py`, `connect4.py`, `ludo.py`, `court_piece.py`)
  keeps its `games` dict in that one process's memory - a second
  instance wouldn't see the first instance's in-progress games at all.
  The consequence: every deploy, every crash, every Cloud Run instance
  recycle **silently drops every in-progress game** for every connected
  player, with no reconnect/resume logic on either the web or mobile
  client - the WebSocket just closes and the player is dumped back to
  the lobby. There's also no way to horizontally scale past whatever one
  container instance (1 vCPU / 512Mi, per the same `describe` output) can
  handle, no matter how much traffic grows.
  - Real fix, if this ever needs to scale: move live game state out of
    process memory into something shared (Redis, or Cloud SQL itself
    with more frequent writes) so any instance can serve any game. That's
    a genuinely significant rewrite, not a config change - worth flagging
    now so it's a deliberate future decision, not a surprise later.
  - Cheaper partial mitigation that *doesn't* require the rewrite:
    graceful-shutdown handling (catch `SIGTERM`, broadcast a "server is
    restarting, reconnecting..." message before the process dies) plus
    client-side auto-reconnect with a grace window. Wouldn't fix the
    scaling ceiling, but would turn "your game just vanished" into "brief
    hiccup, reconnected automatically" for the far more common case (a
    routine deploy) vs. the rare one (an actual crash).
- **DB connection pool (1-10 connections) vs. request concurrency (80)
  is a latent bottleneck.** `containerConcurrency: 80` on Cloud Run,
  `psycopg2.pool.SimpleConnectionPool(1, 10, ...)` in `db.py`, and every
  route handler is a synchronous `def` (not `async def`), which Starlette
  runs in a worker thread pool. Under real concurrent load, requests can
  queue up waiting for one of only 10 DB connections, and
  `db_pool.getconn()` has no timeout - a burst of traffic degrades into
  increasing latency rather than a clean error. Not visible at today's
  traffic level, but worth a load test before assuming it scales.
- **No monitoring or alerting beyond Cloud Run's default request logs.**
  No uptime check, no error-rate alert, no latency alert. If the site
  goes down at 3am, the first signal is a player complaint, not a page.
  Cloud Monitoring uptime checks + a basic alert policy (error rate,
  5xx count) would close this cheaply.
- **No verified disaster-recovery story for Cloud SQL.** Google's
  automated backups exist by default for Cloud SQL, but there's no
  documented restore drill, no point-in-time-recovery test, no answer to
  "if the DB instance is accidentally deleted, what's our actual RPO/RTO."
- **Cold-start readiness race was already found and fixed once this
  session** (the `docker-entrypoint.sh` wait-for-uvicorn loop) - worth
  noting because it's a symptom of the two-processes-in-one-container
  design (see §7's Caddy note) and could resurface in a different form.

## 6. Data & secrets management

- **What's actually done right, for contrast**: `PGPASSWORD`,
  `SESSION_SECRET`, and `GMAIL_APP_PASSWORD` are all in Secret Manager
  (`secretKeyRef`, confirmed via `gcloud run services describe`), not
  plain Cloud Run env vars. Passwords are bcrypt-hashed, never logged,
  never stored in plaintext. Reset/verification tokens are hashed at
  rest (`hash_token()` = SHA-256) and single-use (`used_at` check).
  Password reuse is actively prevented via `password_history`. This is
  all solid - the gaps below are additions, not fixes to broken things.
- **No secret rotation policy.** Nothing rotates `SESSION_SECRET` or
  `PGPASSWORD` on any schedule; if either ever leaked, the only response
  plan is "manually rotate it right now," not a routine practice.
  Rotating `SESSION_SECRET` also has a real cost worth knowing:
  invalidates every active session instantly (it's what signs the
  cookie), so it's a "log everyone out" button, not a transparent
  rotation.
- **DB user privilege scope not verified.** `tictactoe_app` is presumably
  granted broad DML rights on the `tictactoe` database - worth an
  explicit check that it doesn't also have superuser/DDL rights it
  doesn't need (principle of least privilege). One `\du` / `\dp` check
  away from confirming.
- **No request body size limit configured** at the FastAPI/Starlette
  level - relying entirely on Cloud Run's platform-wide ~32MB request
  cap as the only backstop against a large-payload DoS attempt.

## 7. Engineering practices (beyond security)

- **No automated tests.** No test directory under `backend/` at all.
  `mobile/test/widget_test.dart` is the default Flutter counter-app
  boilerplate test, not a real test for this app. Every change in this
  project today is verified by manually curling production or clicking
  through the UI - there's no regression safety net.
- **No CI/CD pipeline.** Deploys are `gcloud builds submit` +
  `gcloud run deploy`, run ad hoc from a dev machine, straight to
  production, with no automated test gate and no staging environment in
  between. This whole session's Court Piece work, for example, was
  validated by testing directly against `alaab.ai` production and the
  live production database.
- **No staging/dev environment.** There is exactly one environment:
  production. No way to test a risky change (a migration, a dependency
  bump) without it immediately being live for real users.
- **`requirements.txt` has zero version pinning** - confirmed by reading
  the file: `fastapi`, `uvicorn`, `psycopg2-binary`, `bcrypt`,
  `itsdangerous`, `python-multipart`, `websockets`, `python-dotenv` are
  all unpinned. Every single Docker build silently pulls whatever the
  latest version of each package happens to be that day - zero build
  reproducibility, and a breaking change or newly-disclosed CVE in a
  dependency can land in production with no warning and no easy way to
  know which build introduced it. This is probably the single cheapest,
  highest-value fix in this whole document: pin exact versions (or at
  minimum compatible-release `~=` bounds) and bump deliberately.
- **No dependency vulnerability scanning** (Dependabot, `pip-audit`,
  `flutter pub outdated --mode=null-safety` equivalent) wired into
  anything.
- **No linting/type-checking gate for the backend.** The mobile app has
  `flutter analyze` (run manually each session, not gated by CI). The
  Python backend has no `ruff`/`flake8`/`mypy` configured at all.
- **`/docs` and `/openapi.json` (FastAPI's auto-generated Swagger UI) are
  effectively unreachable in production today, but by accident, not by
  design.** Verified live: both return `404`. This isn't because
  `main.py` disabled them (`app = FastAPI()` uses the default
  constructor, which enables `/docs` and `/openapi.json`) - it's because
  Caddy's routing (see below) never forwards those specific paths to the
  backend; they fall through to the static-file catch-all and 404 as
  "file not found." That's a routing gap standing in for a security
  decision that was never actually made. Worth making it deliberate:
  either explicitly set `docs_url=None, redoc_url=None` in the `FastAPI()`
  constructor (so it's true regardless of how Caddy's routes evolve), or
  explicitly decide the docs should be reachable and add a route for
  them.

## 8. Architecture simplification worth considering

- **Do we need Caddy at all?** (Directly answering the question asked
  earlier in this session.) It exists because the backend was
  deliberately built as a pure JSON/WebSocket API with zero HTML routes
  - something has to serve `frontend/`'s static files, and Caddy does
  that plus path-routes `/api/*`/`/ws*` to uvicorn so both look like one
  origin. It's not accidental complexity - but it is a second process
  sharing one container, which is exactly what caused the cold-start 502
  race fixed earlier this session (`docker-entrypoint.sh`'s
  wait-for-uvicorn loop exists solely to paper over Caddy's port opening
  before uvicorn is ready). A real alternative: mount `frontend/` in
  FastAPI itself via Starlette's `StaticFiles`, plus a catch-all route
  for the HTML pages. That collapses the container to one process, one
  startup sequence, no readiness race to manage, and one fewer moving
  part to reason about - at the cost of the backend no longer being a
  "pure API, no HTML" by strict definition. Worth a deliberate decision
  either way, rather than Caddy just being "the way it's always been
  done" since the local-laptop era.

---

## Priority short-list

If only tackling a handful of these, roughly in order of
value-for-effort:

1. **Pin `requirements.txt`** - minutes of work, closes a real
   reproducibility/supply-chain gap.
2. **Add `secure=True` to the session cookie** - one line.
3. **Fix the `signup` account-enumeration inconsistency** - make
   `"taken"` responses indistinguishable from generic errors, or accept
   the tradeoff deliberately and document why.
4. **Rate-limit `/api/auth/login`, `/forgot-password`,
   `/resend-verification`** - `slowapi`, in-memory is fine given
   `maxScale=1`.
5. **Validate `Origin` on the 4 WebSocket endpoints** - closes the CSWSH
   gap.
6. **Explicitly set `docs_url=None`** (or deliberately expose docs) -
   stop relying on an accidental routing gap.
7. **Basic uptime/error-rate alerting** in Cloud Monitoring - cheap,
   closes the "we find out from a player" gap.
8. Everything else here (staging environment, CI/CD, tests, the
   in-memory game-state scaling ceiling, mobile secure storage) is
   real but bigger - worth scheduling deliberately rather than
   squeezing in, especially the game-state architecture question, which
   is a design decision, not a bug fix.
