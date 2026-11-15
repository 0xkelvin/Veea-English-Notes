# TRD 07 — Admin Console

**Status:** v1.2. The operator workflow, per-account Audit history tab (§5a) and Premium plan management (§5b) are implemented and verified against local Go (§10). Nin approved the deployment decision (§3.1) on 2026-11-15. The location and stack choices in §2 were made in the v1.0 delivery.
**Date:** 2026-11-15
**Audience:** Nin, frontend and backend engineers, and whoever deploys the console.

## 1. Authority and inputs

This TRD builds on these approved inputs:

- [AGENTS.md](../../AGENTS.md);
- [User Management Product Doc v0.5](../product/user-management.md) §§9, 11;
- [TRD 06 v1.0](06-rbac-user-administration-api.md);
- [TRD 09 v1.0](09-free-premium-entitlements.md);
- the HTTP contract [`backend/api/openapi.yaml`](../../backend/api/openapi.yaml) `1.7.0-trd09`.

The console adds no API, schema or authorization rule. **The Go API is the authorization authority.** The console offers an action only when the server listed it in `allowed_actions` or `assignable_roles` for this actor and target. Every mutation is decided again by the server, which revalidates the actor's role and session inside its transaction. Hiding a button is convenience, never security.

## 2. Location and stack

### 2.1 What exists

- The only frontend is the Flutter mobile app at the repository root. Its `web/` folder holds icons only (no `index.html`), so the app has never been built for the web.
- The Go client in `lib/data/remote/go/` keeps sessions in platform secure storage, with durable generation and in-flight markers built for a phone that must survive restarts.
- There is no web deployment anywhere in the repository. The only container setup is the Rust `cloud/` Dockerfile and docker-compose stack.
- The Go service sends **no CORS headers**, and it serves only the API.
- An existing pattern runs Dart tests against the real Go router: `TestFlutterGo_EndToEnd` plus `scripts/test-flutter-go.sh`.

### 2.2 Choice

**[Technical]** The console is a separate Flutter **web** package, [`admin_console/`](../../admin_console/), with its own `pubspec.yaml`. Its only dependencies are `flutter` and `http`.

| Option | Why not chosen, or why chosen |
|---|---|
| Add the console to the root app (new web platform, second entrypoint) | Would give the mobile app a web target it does not support (SQLite, widgets, notifications), and would ship console code inside the learner app. |
| A new JavaScript or TypeScript stack | Adds a toolchain and a language the repository does not use, for a small internal tool. |
| HTML served by the Go service | Mixes UI into the API binary and would need cookie sessions and CSRF protection. That is a new authentication mode TRD 06 did not approve. |
| **Separate Flutter web package (chosen)** | Same language and tooling as the app; deploys independently as static files; the learner app is untouched. Tests use `flutter test`, and the real-Go harness follows the existing pattern. |

**[Technical]** The console does **not** reuse `GoApiClient`. Its transport ([`transport.dart`](../../admin_console/lib/src/transport.dart)) keeps credentials **in memory only**, which is the safer model for a privileged browser session. Persisting a refresh token in browser storage would let any script injected into the origin reuse a staff session. The transport sends a bearer token, does one single-flight refresh on 401 with one retry, and treats a lost refresh response as an ended session, never resending a possibly consumed token. That last rule matches the mobile client and TRD 01 §8.4 reuse detection.

## 3. Deployment

### 3.1 Deployment decision (approved by Nin, 2026-11-15)

1. **Dedicated admin origin.** The console is served only from its own origin (for example `https://admin.<domain>`), never from the learner app's or the public API's host.
2. **Same-origin proxying.** That origin serves the static console and reverse-proxies `/v1/` to `cmd/api`. The console calls its own origin (`Uri.base.origin`), so the Go API needs **no CORS**, and none will be added.
3. **Restricted network access.** The admin origin is reachable only from the operator network (VPN or IP allowlist). The API's bearer and role checks remain the authorization control; the restriction is defence in depth.
4. **Admin routes blocked on the public learner ingress.** The single `cmd/api` binary serves both learner and admin routes. The public ingress for the learner app must therefore reject `/v1/admin/` and everything under it (for example with `404`) before the request reaches Go. Learner routes (`/v1/auth/*`, `/v1/me*`, `/v1/account-rights/*`, `/v1/learning/*`) stay public. The admin ingress proxies `/v1/` in full, because the console also needs sign-in, refresh, logout and `/v1/me`.

```text
https://admin.<domain>/          -> admin_console/build/web          (operator network only)
https://admin.<domain>/v1/*      -> cmd/api                          (operator network only)
https://api.<domain>/v1/admin/*  -> rejected at the edge (404)       (public learner ingress)
https://api.<domain>/v1/*        -> cmd/api                          (public learner ingress)
```

Deployment configuration (proxy, ingress rules, allowlists, TLS) is **outside this task**; nothing in the repository configures it. These are its release checks:

- from outside the operator network, the admin origin is unreachable;
- through the public ingress, `GET /v1/admin/users` returns the edge's `404`, not the Go `401`;
- through the admin origin, `GET /v1/admin/users` without a token returns the Go `401 unauthorized`, exactly as the local smoke test shows (§10).

**Build and headers**

- `--dart-define=VEEA_ADMIN_API_BASE_URL=…` exists for tests and the dev server, not for cross-origin production.
- **Build:** `cd admin_console && flutter build web --release --no-web-resources-cdn`. This sets `useLocalCanvasKit: true`, so the page loads its own CanvasKit and makes no third-party CDN request (verified, §10).
- **Recommended edge headers:** `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store` on `index.html`, and a Content-Security-Policy limited to `'self'`. The page sets `noindex, nofollow`.
- The Go service and migrations are deployed as in TRD 06 §12. The console needs at least one Super Admin bootstrapped with `bin/admin`.

### 3.2 Local development

[`admin_console/tool/serve.dart`](../../admin_console/tool/serve.dart) is a loopback-only dev server. It serves `build/web` and proxies `/v1/`, `/healthz` and `/readyz` to a loopback Go API (default `http://127.0.0.1:18386`), reproducing the same-origin topology. It refuses a non-loopback upstream.

```sh
cd admin_console && flutter build web --release --no-web-resources-cdn
dart run tool/serve.dart       # http://127.0.0.1:8090
```

## 4. Sign-in and session

| Concern | Behavior |
|---|---|
| Sign-in | Email and password (`POST /v1/auth/password/login`), or an email code (`/v1/auth/otp/start` then `/verify`). The device label is `Veea Admin Console` with platform `web`. |
| Who may enter | After sign-in the console reads `GET /v1/me`. A `user` role gets a **No admin access** page with a sign-out button. Admin and Super Admin get the console. |
| Credentials | In memory only. A reload, a closed tab or sign-out ends the console session. Nothing goes to local storage, cookies, URLs or logs. |
| Access expiry | The 15-minute access token is refreshed transparently once per 401. Concurrent requests share one refresh. |
| Session ended | A failed or lost refresh, or any 401 after refresh, returns to sign-in with *"Your session ended or was revoked. Sign in again to continue."* |
| Sign-out | Clears locally first, then calls `POST /v1/auth/logout` (best effort). |

## 5. The first operator workflow

| Step | UI | API |
|---|---|---|
| Search and list | Email field with **Starts with** (3 or more characters) or **Exact**; status filter; role filter for Super Admins only. *Load more* pages with `next_page_token`. Admins also see *"As an Admin you can see and manage User accounts only."* | `GET /v1/admin/users` |
| Account summary | Email, role and status chips, account ID, display name, verification, password set, created, status and role change times, live session count, last seen. Pending-deletion and suspension call-outs (reason, ticket reference, resume state). | `GET /v1/admin/users/{id}` |
| Session summary | Device list with sign-in and last-seen times, and **Revoke** per session. Shown only when `view_sessions` is allowed. | `GET …/sessions` |
| Suspend or reinstate | Buttons only for `suspend` or `reinstate`. | `POST …/lifecycle-transitions` with `expected_lifecycle_revision` from the loaded detail |
| Change role | Shown only for `change_role`, choosing from `assignable_roles`. On the actor's own account it reads **Step down to User**. | `PUT …/role` with `expected_role_revision` |
| Revoke sessions | **Sign out everywhere** (when live sessions exist) or per-session **Revoke**. | `POST …/session-revocations` |

**Confirmation.** Every mutation opens a dialog that:

- names the target account;
- states the effect (for example, "Promoting … signs the account out on every device", "You lose admin access as soon as this is saved");
- requires one of the API's **fixed reason codes** for that action (TRD 06 §6.5);
- accepts an optional ticket reference, checked with the server's rule.

The confirm button stays disabled until a reason is chosen and any ticket reference is valid. Cancel sends nothing.

**Visibility.** The role filter is shown only to Super Admins. Every action button comes only from the server's lists, and `allowed_actions` is recomputed on every detail load and after every mutation. When nothing is allowed, a sentence explains why: pending deletion, your own account, or your role.

**After success.** The returned `AdminUser` replaces the detail, the list row is updated, sessions are reloaded, and a confirmation notice appears. When a Super Admin steps down, the console re-reads `/v1/me` and moves to **No admin access**.

## 5b. Plans (TRD 09, 2026-11-15)

The account detail shows the server's effective `plan` and `plan_expires_at` in UTC, including for read-only targets. It does not infer effectiveness from the browser clock. Unknown future action values remain ignored.

**Actions and confirmation.** Only `manage_plan` offers **Grant Premium**; **Revoke Premium** additionally requires the returned effective plan to be Premium. Grant can replace an existing grant. Both reuse the existing target-naming confirmation dialog, fixed reason codes (TRD 09 §6) and ticket validation, but a ticket is **required** for plan changes. Grant also requires an explicit RFC3339 expiry with UTC or a numeric offset; the console normalizes it to UTC. The backend enforces that it is after database time and within 366 days. Revoke sends a null expiry. Neither action changes roles, sessions, data or current limits.

**Contract and retries.** `PUT /v1/admin/users/{id}/entitlement` sends `plan`, `ends_at`, `reason_code`, `ticket_ref` and `expected_entitlement_revision`. The confirmation captures the viewed account ID and revision; a selection change or a detail reload with a different revision refuses submission locally. `409 entitlement_conflict` reloads the latest detail and audit history, explains the conflict and requires a new confirmation. There is no automatic conflict replay. The existing transport and backend retry/no-op rules remain authoritative.

**After success.** Reload the account detail and the first audit page, including when the history tab has not yet been opened. The history labels `premium_grant` and `premium_revoke` with their fixed reasons. Permission loss follows §7; the console does not reproduce the backend's role matrix.

## 5a. Audit history tab (added 2026-11-15)

The account view has two tabs: **Overview** (everything in §5) and **Audit history**. The history comes from `GET /v1/admin/users/{id}/audit` (TRD 06 §9a). The server applies the same visibility rule as the detail view, so the tab never decides on its own who may see what.

| Concern | Behavior |
|---|---|
| Loading | The first page loads when the tab is first shown (spinner). The tab resets when another account is opened. |
| Entries | Newest first. Each shows the action ("Suspended", "Reinstated", "Role changed", "Made Super Admin (CLI bootstrap)", "Sessions revoked"), the time, the actor ("you", "staff account 0123abcd…", or "the operator CLI"), the reason label, the ticket reference when present, and a "Failed" chip when the outcome is not success. A scope line says which changes are listed and that entries are kept for 180 days. |
| Paging | **Load older entries** follows `next_page_token` (50 per page). |
| Empty | "No administrative changes in the last 180 days." |
| Error | The mapped message with **Retry**. |
| Refresh | A history already shown reloads after any successful suspend, reinstate, role change or session revocation. A successful plan change reloads the first page even if history has not yet been shown. |
| Permission loss | `403 forbidden` re-reads `/v1/me` and moves to No admin access. `403 target_not_permitted` shows "Your role cannot view this account or its history any more." in the tab. `401` returns to sign-in. `404` closes the account and refreshes the list. |

The tab shows only the API's allowlisted fields. Actor emails are not part of the allowlist, so actors appear by identifier.

## 6. Refusals and messages

Messages come from [`messages.dart`](../../admin_console/lib/src/messages.dart). The server's `title` is never shown.

| Server outcome | Message (abridged) | Console behavior |
|---|---|---|
| `401` / refresh failure | "Your session ended or was revoked. Sign in again…" | Drops credentials; back to sign-in |
| `403 forbidden` | "Your admin access was removed, so the server refused this action…" | Re-reads `/v1/me`; **No admin access** if no longer staff |
| `403 target_not_permitted` | "Your role does not allow this on this account. Its details were reloaded…" | Re-reads `/v1/me`, reloads detail; shows "Your role cannot view this account." if the view is refused |
| `404 not_found` (account) | "This account no longer exists. It may have been deleted. The list was refreshed." | Clears the selection; re-runs the search |
| `404` on one session | "That session had already ended. The list was refreshed." | Reloads detail and sessions |
| `409 lifecycle_conflict`, `role_conflict` | "This account changed while you were viewing it. The latest details are shown…" | Reloads detail (fresh revisions) |
| `409 entitlement_conflict` | "This account's plan changed while you were viewing it… review it and confirm again…" | Reloads detail and audit; never resubmits automatically |
| `400 invalid_expiry` | Choose an expiry after the server's current time and within 366 days | Requires a new confirmation; no automatic retry |
| `409 status_conflict` with `account_status: pending_deletion` | "This account is pending deletion. It cannot be suspended, reinstated or given a new role or plan…" | Reloads detail, which shows the pending-deletion call-out |
| `409 status_conflict`, other status | "This action is not allowed while the account is …" | Reloads detail |
| `409 last_super_admin` | "At least one other active Super Admin must remain. Promote another Super Admin first, then try again." | Reloads detail, which no longer offers the step-down |
| `429` | "Too many admin requests. Wait a minute, then try again." | Nothing sent again automatically |
| `400` | "The server rejected the request. Check the search, reason and ticket reference." | — |
| Network failure | "Cannot reach the server. Check the connection and try again." | — |
| `500` / unknown | "Something went wrong on the server. Try again; if it continues, report it." | — |

**Loading, empty and error states.** The list, detail and sessions each have a spinner, an error message with **Retry**, and an empty state:

- list: "No accounts match this search…", or "There are no accounts you can see yet.";
- sessions: "No live sessions.";
- detail: "Select an account to see its details and actions."

Invalid search input is explained before any request is sent. Notices are dismissible and announced as a live region. At 960 px and wider the list and detail sit side by side; narrower screens show one pane with **Back to list**.

## 7. Permission changes while the console is open

The console never caches authorization. When an operator's role changes elsewhere, the very next request reflects it:

- **Demoted:** the server refuses the next admin request (`403 forbidden`). The console re-reads `/v1/me` and shows **No admin access**. Nothing was changed on the target.
- **Sessions revoked by a Super Admin, or suspended:** the next request fails refresh, and the console returns to sign-in.
- **The target's role or state changed:** `target_not_permitted`, the revision conflicts or `status_conflict` reload the detail, so the offered actions match the server again.

There is no server push; an idle console shows stale data until its next request, which the server then judges.

## 8. API and deployment gaps (recorded, not blocking)

| Gap | Effect | Proposed follow-up |
|---|---|---|
| ~~No audit history read API~~ | **Resolved 2026-11-15:** `GET /v1/admin/users/{id}/audit` (TRD 06 §9a) and the Audit history tab (§5a) | Actor emails and from/to values are outside the allowlist; widen it only by a new decision |
| **No dashboard statistics API** (counts by status or role, recent changes). | No dashboard; the console opens on the account list. | Add a read model only after the metrics in TRD 06 §9.3 prove insufficient |
| No CORS on the Go API | **Decided 2026-11-15:** same-origin proxying on a dedicated admin origin (§3.1), so no CORS is needed | — |
| Deployment configuration | The admin ingress, network allowlist and the public ingress block on `/v1/admin/` are not in the repository (§3.1) | Deployment work, with the release checks in §3.1 |
| **No search by account ID** | Detail by ID works (`GET /v1/admin/users/{id}`); the list searches by email only. | Optional `id` filter on `listAdminUsers` |
| **No staff session policy** | Staff sessions follow the learner lifetimes (refresh up to the TRD 01 limits); the console only shortens them by keeping tokens in memory. | TRD 06 §13 left step-up and short staff sessions open |

## 9. Code map

| Area | File |
|---|---|
| Entry and base URL | [`admin_console/lib/main.dart`](../../admin_console/lib/main.dart) |
| Transport (memory-only tokens, refresh, problems) | [`lib/src/transport.dart`](../../admin_console/lib/src/transport.dart) |
| Typed TRD 06 calls | [`lib/src/admin_api.dart`](../../admin_console/lib/src/admin_api.dart) |
| Contract projections, reason codes, ticket rule, search | [`lib/src/models.dart`](../../admin_console/lib/src/models.dart) |
| Workflows and refusal handling | [`lib/src/console_controller.dart`](../../admin_console/lib/src/console_controller.dart) |
| Messages | [`lib/src/messages.dart`](../../admin_console/lib/src/messages.dart) |
| UI | [`lib/src/ui/`](../../admin_console/lib/src/ui/) (`app.dart`, `console_page.dart`, `action_dialog.dart`) |
| Dev server | [`tool/serve.dart`](../../admin_console/tool/serve.dart) |
| Tests | [`test/`](../../admin_console/test/): widget, transport, and the e2e suite in `test/e2e/` |
| Real-Go harness | [`backend/test/integration/flutter_admin_e2e_test.go`](../../backend/test/integration/flutter_admin_e2e_test.go), [`backend/scripts/test-flutter-admin.sh`](../../backend/scripts/test-flutter-admin.sh), `make -C backend test-flutter-admin` |

## 10. Verification — 2026-11-15

All runs used local services only: a disposable loopback PostgreSQL and synthetic accounts, never a deployed server. The following table records the original v1.1 verification; §10.1 records the subsequent plan UI checks.

| Check | Command | Actual result |
|---|---|---|
| Console analyzer | `cd admin_console && flutter analyze` | No issues |
| Console unit and widget tests | `cd admin_console && flutter test` | **31 passed, 6 skipped** (the e2e file skips without its environment). 26 widget tests (below) and 5 transport tests (single-flight refresh, refused and lost refresh, problem parsing, no tokens in URLs, malformed sign-in, logout) |
| Console against real Go | `backend/scripts/test-flutter-admin.sh` (`TestFlutterGo_AdminConsole`, `-race`) | **Go test passed. Dart: 6 ran, 6 passed, 0 skipped.** Every exchange was validated by the OpenAPI response checker, and the harness's hygiene, no-retry and log checks passed |
| Web build | `flutter build web --release --no-web-resources-cdn` | Built; `useLocalCanvasKit: true` |
| Same-origin smoke | `bin/migrate up` and `bin/api` on a disposable database with throwaway keys, behind `dart run tool/serve.dart` | Console served (`<title>Veea Admin Console</title>`, security headers). `/healthz` 200 through the proxy. `/v1/admin/users` without a token: `401 unauthorized` with `WWW-Authenticate: Bearer`. Unknown paths fall back to `index.html` |
| Bootstrap CLI smoke | `bin/admin bootstrap-super-admin --email …` twice | First run promoted (`role_revision=1`, exit 0). Second run refused (exit 1). One `admin.role.bootstrap` row with a null actor, reason `bootstrap`, mode `first` |
| Root app analyzer | `flutter analyze` (repository root) | No issues; the learner app is unchanged |

**Against real Go** (`admin_console/test/e2e/admin_console_e2e_test.dart`):

1. **Admin:** sees only User accounts, and an exact search for a staff email finds nothing. On a User the detail offers exactly `suspend`, `view_sessions` and `revoke_sessions`. Revoking one session leaves 1 live in the database. Suspension with ticket `SUP-1042` signs out everything and offers `reinstate`. Reinstatement returns the account to active. Opening a staff account shows "Your role cannot view this account.".
2. **Super Admin:** lists Super Admins. Promotion to Admin revokes every session (0 live), then demotion. A pending-deletion target offers only session actions, and a stale Suspend gets `status_conflict` with the pending-deletion message. After suspending the other Super Admin, self step-down is not offered, and a forced attempt gets `last_super_admin`. After reinstating them, stepping down succeeds and the console moves to No admin access.
3. **Permission change refused by the server:** an Admin's console has Suspend available on a User. A Super Admin demotes that Admin in another console. The Admin's Suspend gets `403 forbidden`, and the console shows No admin access with the access-removed message. The target stayed active with its session, and the demoted Admin's sessions were kept.
4. **Session expiry:** an expired access token is refreshed silently. After a Super Admin revokes the Admin's sessions, the Admin's next request returns to sign-in with the session-ended message, and the credentials are dropped.
5. A User account cannot enter the console.
6. **Audit history (2026-11-15):**
   - In test 1, the Admin's history is `reinstate`, `suspend`, `sessions_revoke`, newest first, with reasons `appeal_upheld`, `abuse`, `security_review`, ticket `SUP-1042` on the suspension only, and the Admin as actor. The staff account's history is refused with the target-not-permitted message, while the console stays usable.
   - In test 2, the two role changes page one entry at a time (`access_review`, then `staffing_change`, by the Super Admin), and a Super Admin views its own (empty) history.
   - A sixth test: an Admin's revocation with ticket `SUP-77` appears in the Admin's history and in the Super Admin's view with the Admin as actor. After the Admin is demoted, its next history request moves it to No admin access. A second Admin whose sessions are revoked while viewing history returns to sign-in.

**Widget tests (fake TRD 06 backend, `test/support/fake_backend.dart`):**

- no-access page; wrong password; email-code sign-in;
- Admin view (no role filter, no role action, no staff rows); Super Admin view (role filter, last Super Admin offered nothing);
- list loading, prefix validation, empty and error-with-retry states; detail loading and error states;
- suspend dialog: reason required, invalid and token-shaped tickets refused, cancel sends nothing; then reinstate;
- promotion with role and reason; single and all session revocation;
- silent access refresh; revoked session returns to sign-in;
- demoted mid-session; target promoted elsewhere (`target_not_permitted`);
- pending deletion (banner, no actions, conflict message); `last_super_admin` and a stale revision;
- Super Admin step-down; account deleted while open; narrow layout;
- Audit history tab: empty state; loading, then entries with actor, reason and ticket, refreshed after a change; paging with *Load older entries*; error with retry; demoted actor leaves the console; target became staff; session ended while viewing.

### 10.1 Premium plan UI verification — 2026-11-15

Run from the repository root unless a package directory is shown. These checks used only synthetic accounts and disposable local PostgreSQL; no deployed service was contacted. The backend API, migrations and OpenAPI contract are unchanged by the UI work.

| Check | Command | Actual result |
|---|---|---|
| Console analyzer | `cd admin_console && flutter analyze` | **No issues** |
| Full console suite | `cd admin_console && flutter test --reporter json` | **42 passed, 0 failed, 10 skipped**. The 10 real-Go E2E cases skip without their harness environment; all ran separately below |
| New plan widget cases | Included in `test/plan_widget_test.dart` above | **11 passed, 0 failed, 0 skipped** |
| Local Go E2E | `make -C backend test-flutter-admin` | **Dart: 10 passed, 0 failed, 0 skipped**. **Go host: 1 passed, 0 failed, 0 skipped**, with `-race`. The existing OpenAPI exchange checker and hygiene checks passed |

The 11 new widget cases cover server plan/expiry display; capability-only action visibility; self and pending-deletion targets; required reason, ticket and explicit valid expiry; cancellation; exact grant/revoke payloads with revisions; detail and initially unopened audit refresh; stale revision from another console; a revision reload or account switch while confirming; actor and target permission loss; and a backend `invalid_expiry` response. A conflict never causes automatic resubmission, and reopening requires new input and confirmation.

Four new local-Go cases cover grant and revoke with retained sessions and exact audit fields (including no duplicate event on a same-state retry); a second console changing the revision and an explicit fresh confirmation; actor demotion; and target promotion beyond the actor's authority. They run through the production router using the console API/controller and the existing six E2E cases also pass. Widget tests exercise the corresponding dialogs. No contract gap was found. The backend's full PostgreSQL + Mailpit suite recorded in TRD 09 §11 was not rerun for this UI-only change. Deployment checks in §3.1 remain release gates; the first Premium feature and payments remain outside this scope.

## 11. Decision record

1. **Hosting — decided 2026-11-15:** dedicated admin origin with same-origin proxying; no CORS (§3.1).
2. **Network restriction — decided 2026-11-15:** operator network only, and `/v1/admin/` blocked on the public learner ingress (§3.1). The configuration is deployment work outside the repository.
3. **Audit history — delivered 2026-11-15:** TRD 06 §9a and §5a.
4. **Premium plan management — delivered 2026-11-15:** existing TRD 09 decisions implemented in §5b; no new backend contract or permission rule.

Staging, commits and pushes are left to Nin.
