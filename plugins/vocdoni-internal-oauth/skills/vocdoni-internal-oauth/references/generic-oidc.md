# Other stacks and unchangeable tools

## Any OpenID Connect client library

`oauth.vocdoni.org` is a standard OpenID Connect provider. Any maintained
library works (Python `authlib`, Ruby `omniauth_openid_connect`, PHP
`jumbojett/openid-connect-php`, Rust `openidconnect`, Java Spring Security
OAuth2 Client), as does an OIDC option a product already has (Folio uses
`FOLIO_OIDC_*`). Configure it as:

| Setting | Value |
| --- | --- |
| Issuer / discovery | `https://oauth.vocdoni.org` (`/.well-known/openid-configuration`) |
| Client type | confidential (client secret), `client_secret_basic` or `client_secret_post` |
| Flow | authorization code, **PKCE S256 required** (the provider rejects requests without it) |
| Scopes | `openid email profile` (nothing else; never `offline_access`) |
| Redirect URI | the exact URL registered for the client |
| Claims | `sub`, `email`, `email_verified`, `name` |

The library or your code must:

1. Send `state` and `nonce` (random, at least 128 bits), keep them with the
   PKCE verifier in a short-lived (at most 10 min), HttpOnly, SameSite=Lax,
   encrypted or server-side store, and compare them on the callback in
   constant time.
2. Verify the ID token: signature via the provider's JWKS (refetch on an
   unknown `kid`), `iss == https://oauth.vocdoni.org`, `aud == client id`,
   `exp` (allow about 60 s skew), `nonce`.
3. Admit only `email_verified == true` (the JSON boolean) and an e-mail whose
   domain is exactly `vocdoni.org` (or an explicit allow list).
4. Create the tool's own session (HttpOnly, Secure, SameSite=Lax cookie). A
   Strict cookie set on the callback is dropped after the cross-site redirect
   chain and the user lands signed out.
5. Redirect after login only to a validated same-origin relative path. Watch
   for path cleaning: `/../\evil.example` becomes `/\evil.example`, which
   browsers treat as `//evil.example`. Reject backslashes, dot segments
   (also percent-encoded `%2e`), control characters and `//` prefixes.
6. Make sign-out a same-origin POST.
7. Never show provider error strings to users; log them server side.
8. Fetch discovery lazily (on first login, with backoff) so the tool starts
   while the provider is down.

Python (Flask + Authlib) shape, for orientation:

```python
oauth.register(
    "vocdoni",
    server_metadata_url="https://oauth.vocdoni.org/.well-known/openid-configuration",
    client_id=os.environ["OAUTH_CLIENT_ID"],
    client_secret=os.environ["OAUTH_CLIENT_SECRET"],
    client_kwargs={"scope": "openid email profile", "code_challenge_method": "S256"},
)
# login:    return oauth.vocdoni.authorize_redirect(os.environ["OAUTH_REDIRECT_URL"])
# callback: token = oauth.vocdoni.authorize_access_token(); claims = token["userinfo"]
#           require claims["email_verified"] is True and claims["email"].lower().endswith("@vocdoni.org")
```

Check the library's documentation for nonce and PKCE handling in the version
the project uses.

## oauth2-proxy

For a tool whose code cannot change (or a static site), put
[oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) in front of it.
The recipe lives in `docs/proxy.md` of `vocdoni/oauth` and is marked
**untested**; test it locally before relying on it.

- Register the proxy's callback:
  `make add-client ID=mytool URL=https://mytool.vocdoni.io/oauth2/callback`.
- Key flags: `--provider=oidc --oidc-issuer-url=https://oauth.vocdoni.org
  --code-challenge-method=S256 --scope="openid email profile"
  --email-domain=vocdoni.org --cookie-secure=true --upstream=<tool on the private network>`.
- Route the public hostname to the proxy only, never to the tool directly
  (on Railway the tool gets no public domain; only the proxy does).
- Pin the oauth2-proxy image by digest.
