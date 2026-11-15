# Veea Admin Console

Operator console for Veea English Notes (TRD 07, `docs/trd/07-admin-console.md`). Flutter web,
separate from the learner app at the repository root. It calls the Go admin API (TRD 06); the API
is the authorization authority and the console only offers what the server allows.
Account detail includes the effective plan and UTC expiry. `manage_plan` offers confirmed
Premium grants and revocations with fixed reasons, required tickets and a grant expiry.
Stale entitlement revisions reload the latest detail and require a fresh confirmation.

```sh
flutter pub get
flutter analyze && flutter test                      # unit + widget tests (e2e skips here)
flutter build web --release --no-web-resources-cdn   # static files in build/web
dart run tool/serve.dart                             # local same-origin server -> Go API on 127.0.0.1:18386
make -C ../backend test-flutter-admin                # console against the real Go router + local PostgreSQL
```

Deploy `build/web` on the same origin as the API (reverse proxy `/v1/` to `cmd/api`); the Go API
sends no CORS headers. Credentials are kept in memory only, so reloading the page signs out.
