# Operations

The central service is Dex on Railway (one service, `oauth`, image
`ghcr.io/vocdoni/oauth:latest`, volume `/data`). Its configuration is
`config.yaml` in `github.com/vocdoni/oauth`; secrets are Railway variables
only.

## Register a tool

One client per tool and per environment (staging and production are
different clients with different callback URLs).

```sh
cd vocdoni/oauth
make add-client ID=mytool URL=https://mytool.vocdoni.io/auth/callback NAME="My tool"
```

- `ID` matches `^[a-z0-9][a-z0-9-]{1,31}$`; it becomes the `client_id`.
- The script appends the client to `config.yaml` and prints the variable
  name: the id upper-cased with every character outside `[A-Z0-9]` replaced
  by `_` (`my-tool` becomes `CLIENT_MY_TOOL_SECRET`).
- Generate the secret with `openssl rand -hex 32` and set it on the Railway
  `oauth` service **first** (the container stops if any registered client's
  secret is missing), then open a pull request with the `config.yaml` change.
- CI loads the new config in the real image with unknown fields disallowed.
- After the merge, CI publishes and promotes `latest`; **redeploy the
  `oauth` service** in Railway (Deployments, Redeploy) so Dex picks up the
  client. A deploy costs a few seconds of sign-in downtime; existing tool
  sessions are unaffected.
- Give the same secret to the tool as `OAUTH_CLIENT_SECRET`.

These are production changes to shared infrastructure: confirm with the user
before setting variables, merging or redeploying.

## Local development

```sh
cd vocdoni/oauth
make dev PASSWORD=<pick one>      # dev provider on http://localhost:5556
```

- User `dev@vocdoni.org` with that password (a password database instead of
  Google).
- Client `dev`, secret `dev-client-secret`, redirect URI
  `http://localhost:8080/auth/callback`.
- Tool environment: `OAUTH_ISSUER=http://localhost:5556 OAUTH_CLIENT_ID=dev
  OAUTH_CLIENT_SECRET=dev-client-secret OAUTH_INSECURE=1
  OAUTH_REDIRECT_URL=http://localhost:8080/auth/callback
  OAUTH_COOKIE_KEYS="$(openssl rand -base64 32)"`.
- `make dev-down` stops it. If the tool runs on another port, add a dev
  client to `dev/config.yaml` locally instead of registering localhost on
  production.

## Migrating from a shared password

1. Ship the kit next to the existing password login (both work). Keep the
   password as a fallback while the SSO path is new.
2. Register the client, set the tool's `OAUTH_*` variables, deploy.
3. Have a `@vocdoni.org` user sign in through SSO in production and check
   that the tool records the e-mail (activity or audit logs).
4. Remove the password: delete the code path (or the variable that enables
   it) and its secret. If the variable holds the only copy of a value
   someone may need again, save it to the team's secret store first. Without
   a password the route should answer 404, not accept an empty password:
   test that.
5. Rollback: re-enable the password variable or redeploy the previous image.

Folio is the reference: generic `FOLIO_OIDC_*` variables, password fallback
during the rollout, then SSO only.

## Cookie keys

- `OAUTH_COOKIE_KEYS` is a comma-separated list of base64 32-byte keys. The
  first encrypts; any decrypts.
- Rotate without signing everyone out: prepend a new key, deploy, wait at
  least the session lifetime (12 h by default), then drop the old key.
- Sign everyone out at once: replace the list with a single new key.
- Sessions are stateless and absolute (12 h by default, at most 7 days). A
  suspended Workspace account cannot sign in again, but an existing session
  lasts until it expires or the keys rotate.
- Every replica of a tool must use the same keys, or a callback that lands
  on another replica fails with `state`.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Provider page "Unregistered redirect_uri" or "Invalid redirect URI" | `OAUTH_REDIRECT_URL` differs from the registered URL (scheme, host, port, path, trailing slash). Fix one side; register a separate client per environment. |
| `{"error":"sso_unavailable"}` / 503 on sign-in | The tool cannot reach `https://oauth.vocdoni.org/.well-known/openid-configuration` (egress, DNS, provider down). Check `curl -fsS https://oauth.vocdoni.org/healthz`. |
| 403 `state` | The state cookie is missing or expired: sign-in started in another tab, took more than 10 minutes, the cookie was blocked, or replicas use different cookie keys. |
| 403 `token` | ID token rejected: wrong `OAUTH_CLIENT_ID`, wrong issuer, a large clock skew, or a proxy rewrote the request. |
| 403 `exchange` | Wrong client secret, or the secret on Railway and in the tool differ. |
| 403 `domain` | Account not `@vocdoni.org`, unverified e-mail, or not in the tool's allowed-emails list. Personal Gmail accounts are refused earlier by Google (Internal app). |
| 403 `origin` on sign-out | Sign-out must be a same-origin POST form, not a GET link or a cross-origin `fetch`. |
| Signed in, then immediately signed out on localhost | Secure cookie over http: set `OAUTH_INSECURE=1` (development only). |
| Every request after login is 401 | The cookie is not sent: the tool is served on a different host than `OAUTH_REDIRECT_URL`, or a proxy strips cookies. |
| The Dex container exits after adding a client | `CLIENT_<ID>_SECRET` is not set on the `oauth` service, or `config.yaml` has a typo (unknown fields stop the container). |

Provider status: `curl -fsS https://oauth.vocdoni.org/.well-known/openid-configuration | jq .issuer`.
