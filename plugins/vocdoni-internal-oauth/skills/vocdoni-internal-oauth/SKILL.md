---
name: vocdoni-internal-oauth
description: Integrates an existing Vocdoni internal web tool with the central Vocdoni sign-in service at https://oauth.vocdoni.org (Dex OpenID Connect provider backed by Google Workspace, @vocdoni.org accounts only) so staff sign in with Google instead of a shared password. Covers registering the tool as a client in the vocdoni/oauth repo, the per-tool Railway secret, the Go kit (github.com/vocdoni/oauth/go, package vocauth), the Node/TypeScript kit (@vocdoni/oauth on openid-client, Express or any Fetch-API framework such as Next.js or Hono), generic OpenID Connect clients for other stacks, an oauth2-proxy option for tools whose code cannot change, local development against a dev provider, migrating from a single-password login, cookie-key rotation and troubleshooting. Use this whenever the user wants to add Google/SSO/OAuth/OIDC login or "the central oauth" to an internal app, replace a password-protected admin UI, protect an internal dashboard, or asks how oauth.vocdoni.org, vocauth or @vocdoni/oauth work.
---

# Vocdoni internal sign-in (oauth.vocdoni.org)

Internal tools never talk to Google. They are OpenID Connect clients of one
central provider, `https://oauth.vocdoni.org`, which is the only place where
Google is configured. Integrating a tool means: register it as a client,
give it a secret, add the kit (or any OIDC client), and remove its old
password.

```
browser ──> tool ──302──> oauth.vocdoni.org (Dex) ──302──> Google (Internal app, hd=vocdoni.org)
             ^  <── /auth/callback?code ──┘   code → token (server to server, client secret + PKCE)
             └── tool's own session cookie (ID token verified against oauth.vocdoni.org/keys)
```

Facts to rely on (do not re-derive or contradict them):

- Issuer: `https://oauth.vocdoni.org` (discovery at
  `/.well-known/openid-configuration`). Authorization code flow only, PKCE
  `S256` is **enforced**, no refresh tokens, ID tokens live 10 minutes and
  are used once at login.
- Only verified `@vocdoni.org` Google accounts get through (Google Internal
  consent screen + Dex `hostedDomains`); the kits check the domain again.
- ID token claims: `sub`, `email`, `email_verified`, `name`. **No
  `picture`**, no groups.
- Each tool keeps its **own** session. There is no central session and no
  central logout; "sign in once" comes from the browser's Google session
  (the second tool shows at most an account chooser).
- Redirect URIs match **exactly**; there are no wildcards and production
  clients list production URLs only.
- Source of truth: repo `github.com/vocdoni/oauth` (service config, kits,
  examples, README). Check it when something here looks out of date.

## Workflow

1. **Pick the integration** (first match wins):

   | The tool is… | Use |
   | --- | --- |
   | Go (`net/http`, chi, echo via adapters…) | Go kit, see [references/go.md](references/go.md) |
   | Node/TypeScript (Express, Next.js, Hono, Fastify via adapter…) | Node kit, see [references/node.md](references/node.md) |
   | Another stack, or a codebase that already has an OIDC library | Generic OIDC client, see [references/generic-oidc.md](references/generic-oidc.md) |
   | Code you cannot change, or a static site | oauth2-proxy in front, see [references/generic-oidc.md](references/generic-oidc.md#oauth2-proxy) |

   Prefer a kit: both kits implement the same reviewed flow (PKCE, state,
   nonce, signature/audience/expiry checks, domain admission, open-redirect
   and logout-CSRF protection) with identical cookies.

2. **Register the client** in `vocdoni/oauth` (one per tool and environment,
   exact callback URL). Details and the deploy step are in
   [references/operations.md](references/operations.md#register-a-tool):

   ```sh
   git clone git@github.com:vocdoni/oauth.git && cd oauth
   make add-client ID=mytool URL=https://mytool.vocdoni.io/auth/callback NAME="My tool"
   # prints the Railway variable to set: CLIENT_MYTOOL_SECRET
   openssl rand -hex 32   # the client secret
   ```

   Set `CLIENT_MYTOOL_SECRET` on the Railway `oauth` service **before**
   merging (Dex refuses to start while a client's secret is missing), open a
   pull request with the `config.yaml` change, merge, then **redeploy** the
   `oauth` service (a new `latest` image is not picked up by itself).
   Registering a client is a production change to shared infrastructure:
   confirm with the user before pushing or deploying.

3. **Configure the tool** (same names for both kits and the examples):

   | Variable | Value |
   | --- | --- |
   | `OAUTH_ISSUER` | `https://oauth.vocdoni.org` |
   | `OAUTH_CLIENT_ID` | the id from step 2, e.g. `mytool` |
   | `OAUTH_CLIENT_SECRET` | the secret from step 2 (secret store only, never the repo) |
   | `OAUTH_REDIRECT_URL` | the exact callback URL registered in step 2 |
   | `OAUTH_COOKIE_KEYS` | `openssl rand -base64 32`; comma-separated list to rotate (first encrypts, any decrypts) |

4. **Wire the kit**: mount the `/auth/` routes, wrap everything else in
   `Require`, read the user from the request, add a POST sign-out form, and
   plug a rate limiter into the `Limiter` hook. Exact code per kit in the
   references.

5. **Migrate away from the old password** (if the tool had one): ship the
   kit next to the password, sign in through SSO once in production, then
   remove the password path and its secret. See
   [references/operations.md](references/operations.md#migrating-from-a-shared-password).

6. **Verify** before calling it done:

   ```sh
   curl -sI https://mytool.vocdoni.io/            # 302 to /auth/login (browser) or 401 JSON (API)
   curl -s -o /dev/null -w '%{redirect_url}\n' https://mytool.vocdoni.io/auth/login
   # → https://oauth.vocdoni.org/auth?client_id=mytool&...&code_challenge_method=S256&redirect_uri=<exact URL>
   ```

   Then one real sign-in by a person with a `@vocdoni.org` account (an agent
   cannot complete Google's login).

## Rules

- **Never** call Google directly from a tool, never create another Google
  OAuth client, and never ask for Google scopes: the central provider is the
  only Google client.
- Every tool is a **confidential** client (secret + PKCE). No public/SPA-only
  clients: a browser-only app needs a small backend or oauth2-proxy.
- Secrets (client secret, cookie keys) live in the tool's secret store
  (Railway variables, etc.). Never commit them, never log them, never put
  them in front-end bundles.
- Sign-out is a **same-origin POST** form (`<form method="post"
  action="/auth/logout">`). GET links to `/auth/logout` get 405, and
  cross-site posts get 403. Tell users sign-out does not end their Google
  session.
- Keep the default admission (`vocdoni.org`) unless the tool must be narrowed;
  narrow with an allowed-emails list (which then replaces the domain default).
- Do not add a `picture`/avatar from the token (there is none) and do not
  expect groups or roles from the provider; authorization beyond "is a
  Vocdoni staff member" is the tool's own job (e.g. an allowed-emails list or
  the tool's own role table keyed by e-mail).
- Use the e-mail (lower-cased) as the user identity for audit logs and
  authorship; `sub` is stable per provider but not human-readable.
- Local development uses the dev provider from `vocdoni/oauth`
  (`make dev PASSWORD=...`, client `dev`, `http://localhost:8080/auth/callback`)
  with `OAUTH_INSECURE=1`; never register `localhost` URLs on the production
  provider.

## Reference files

| File | Read it when |
| --- | --- |
| [references/go.md](references/go.md) | Integrating a Go tool with `vocauth` |
| [references/node.md](references/node.md) | Integrating a Node/TypeScript tool with `@vocdoni/oauth` (Express, Next.js, Hono) |
| [references/generic-oidc.md](references/generic-oidc.md) | Other languages, existing OIDC libraries, oauth2-proxy for unchangeable tools |
| [references/operations.md](references/operations.md) | Registering clients, secrets, local dev, migrating from passwords, key rotation, troubleshooting |

Related skills: [[go-best-practices]], [[go-code-quality]] for the Go side.
