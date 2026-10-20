# Go kit: `github.com/vocdoni/oauth/go` (package `vocauth`)

```sh
go get github.com/vocdoni/oauth/go@v0.1.0   # tag go/v0.1.0; check the repo for newer go/vX.Y.Z tags
```

The module lives in the `go/` subdirectory, so the version is `v0.1.0`, not
`go/v0.1.0`. Dependencies: `github.com/coreos/go-oidc/v3`,
`golang.org/x/oauth2`. Minimum Go 1.26.

## Wiring

```go
import vocauth "github.com/vocdoni/oauth/go"

keys, err := vocauth.ParseCookieKeys(os.Getenv("OAUTH_COOKIE_KEYS")) // comma-separated base64 32-byte keys
if err != nil {
	log.Fatal(err)
}
auth, err := vocauth.New(vocauth.Config{
	Issuer:       envOr("OAUTH_ISSUER", "https://oauth.vocdoni.org"),
	ClientID:     os.Getenv("OAUTH_CLIENT_ID"),
	ClientSecret: os.Getenv("OAUTH_CLIENT_SECRET"),
	RedirectURL:  os.Getenv("OAUTH_REDIRECT_URL"), // exact registered URL of GET /auth/callback
	CookieKeys:   keys,
	Insecure:     os.Getenv("OAUTH_INSECURE") == "1", // localhost dev only
	Limiter:      limiter.Allow,                     // func(*http.Request) bool, see below
	// AllowedDomains: []string{"vocdoni.org"} (default when both lists are empty)
	// AllowedEmails:  []string{"alice@vocdoni.org"} (narrows the tool to these people)
	// MaxAge:         12 * time.Hour (default; absolute, not sliding; max 7 days)
	// Logger:         slog logger for refusal reasons (default slog.Default())
})
if err != nil {
	log.Fatal(err) // configuration error; New does no network I/O
}

mux := http.NewServeMux()
mux.Handle("/auth/", auth.Routes())            // GET /auth/login, GET /auth/callback, POST /auth/logout
mux.Handle("/healthz", healthz)                 // public routes go before/outside Require
mux.Handle("/", auth.Require(appHandler))       // everything else needs a session
```

In handlers:

```go
u, ok := vocauth.FromContext(r.Context()) // vocauth.User{Subject, Email (lower-cased), Name}
```

Sign-out (POST, same origin):

```html
<form method="post" action="/auth/logout"><button>Sign out</button></form>
<p>Signing out here does not sign you out of Google.</p>
```

## Behaviour to rely on

- `New` validates config only; provider discovery and JWKS fetches are lazy,
  cached and retried with backoff. The tool starts even if
  `oauth.vocdoni.org` is down; sign-in then answers 503 `sso_unavailable`.
- `Require`: a `GET`/`HEAD` whose `Accept` contains `text/html` is redirected
  (302) to `/auth/login?return_to=<path>`; anything else gets
  `401 {"error":"unauthenticated"}` with `WWW-Authenticate: Cookie`. SPAs
  should treat 401 from their API as "navigate to `/auth/login`".
- `return_to` is accepted only as a same-origin relative path (no `//`, no
  backslash, no dot segments, printable ASCII, at most 2048 bytes); otherwise
  `/`.
- Errors answer JSON `{"error":code}` (an HTML page for browsers): 403
  `state`, `exchange`, `token`, `domain`, `provider`, `origin`; 503
  `sso_unavailable`; 429 `rate_limited`; 401 `unauthenticated`; 405
  `method_not_allowed`. Provider error text is logged, never shown.
- Cookies: `vocauth_session` and `vocauth_state`, host-only, `Path=/`,
  HttpOnly, Secure (unless `Insecure`), SameSite Lax, AES-256-GCM. Same format
  as the Node kit, so a Go and a Node service on the same host share sessions
  when they share keys.

## Mounting under a prefix or with routers

The kit's routes are fixed at `/auth/...` relative to the host. If the tool
lives under a path prefix behind a proxy, strip the prefix before the mux or
register the callback URL accordingly. With chi, echo or gin, mount
`auth.Routes()` as an `http.Handler` on `/auth/*` and wrap protected groups
with `auth.Require` (they all accept `func(http.Handler) http.Handler`
middleware or have an adapter).

## Rate limiting

The kit allows everything by default. Pass a limiter that keys on the real
client IP (behind Railway or another proxy, read the proxy's client-IP
header, not `RemoteAddr`). A fixed window of about 20 requests per minute per
IP on `/auth/login` and `/auth/callback` is enough; `examples/go/main.go` in
`vocdoni/oauth` has a complete limiter.

## Tests

Do not hit `oauth.vocdoni.org` from tests. Either:

- test your handlers with a context that already carries a user (wrap them
  without `Require`), or
- run a fake provider with `httptest` (discovery, JWKS with an RSA key,
  `/token` issuing signed ID tokens), as `go/fakeop_test.go` in
  `vocdoni/oauth` does, and point `Issuer` at it with `Insecure: true`.

Complete runnable example: `examples/go` in `github.com/vocdoni/oauth`.
