# Node kit: `@vocdoni/oauth`

TypeScript, ESM, Node 20 or newer, built on `openid-client` v6 (ID token
signature checks enabled). Not on npm yet; install the release tarball (no
token needed):

```sh
npm i https://github.com/vocdoni/oauth/releases/download/node/v0.1.0/vocdoni-oauth-0.1.0.tgz
# check https://github.com/vocdoni/oauth/releases for newer node/vX.Y.Z releases
```

Because it uses `node:crypto`, run it in the **Node.js runtime** (not an Edge
runtime).

## Configuration

```js
import { parseCookieKeys, vocdoniAuth } from '@vocdoni/oauth';

export const auth = vocdoniAuth({
  issuer: process.env.OAUTH_ISSUER ?? 'https://oauth.vocdoni.org',
  clientId: process.env.OAUTH_CLIENT_ID,
  clientSecret: process.env.OAUTH_CLIENT_SECRET,
  redirectUrl: process.env.OAUTH_REDIRECT_URL,      // exact registered URL of GET /auth/callback
  cookieKeys: parseCookieKeys(process.env.OAUTH_COOKIE_KEYS ?? ''),
  insecure: process.env.OAUTH_INSECURE === '1',      // localhost dev only
  limiter: createLimiter(),                          // (req, ctx) => boolean; ctx.ip is the client IP
  // allowedDomains: ['vocdoni.org']  (default when both lists are empty)
  // allowedEmails: ['alice@vocdoni.org']  (narrows the tool to these people)
  // maxAge: 12 * 3600  (seconds, absolute, at most 7 days)
  // logger: { warn(msg, attrs) {} }
});
```

The user object is `{ subject, email /* lower-cased */, name }`.

## Express

```js
import express from 'express';

const app = express();
app.set('trust proxy', 1);           // behind Railway or another proxy, so req.ip is the client
app.get('/healthz', (_req, res) => res.send('ok')); // public routes before require()
app.use(auth.routes());              // GET /auth/login, GET /auth/callback, POST /auth/logout
app.use(auth.require());             // everything below needs a session; sets req.user
app.get('/', (req, res) => res.send(`Hello ${req.user.name}`));
app.get('/api/me', (req, res) => res.json(req.user));
```

Sign-out form (POST, same origin):

```html
<form method="post" action="/auth/logout"><button>Sign out</button></form>
```

Complete example with a limiter: `examples/express` in
`github.com/vocdoni/oauth`.

## Any Fetch-API framework (Next.js, Hono, Bun)

The framework-neutral API takes and returns standard `Request`/`Response`:

```ts
const res = await auth.handle(request, { ip });  // Response for /auth/* routes, null otherwise
const user = auth.user(request);                  // User | null (reads the session cookie)
const deny = auth.challenge(request);             // 302 to /auth/login for browsers, 401 JSON otherwise
```

Next.js (App Router) sketch, Node.js runtime:

```ts
// app/auth/[...path]/route.ts
import { auth } from '@/lib/auth';
export const runtime = 'nodejs';
const route = async (req: Request) => (await auth.handle(req)) ?? new Response('Not found', { status: 404 });
export { route as GET, route as POST };
```

```ts
// in a server component, route handler or server action that needs a user
import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { auth } from '@/lib/auth';

export async function requireUser() {
  const h = await headers();
  // auth.user only reads the Cookie header; any absolute URL on the tool's origin works
  const user = auth.user(new Request(process.env.APP_URL!, { headers: h }));
  if (!user) redirect('/auth/login');
  return user;
}
```

Edge middleware cannot run the kit (it needs `node:crypto`). Protect pages in
server code as above, or use middleware on the Node.js runtime if the
project's Next.js version supports it. Verify the Next.js APIs for the version
in the repository before copying.

## Behaviour

Identical to the Go kit (same cookies, codes and rules): lazy discovery with
backoff (503 `sso_unavailable` while the provider is down), `require()`
redirects browser GETs and answers 401 JSON otherwise, `return_to` limited to
same-origin relative paths, POST-only same-origin logout (403 `origin`
otherwise), errors as `{"error":code}` without provider text, 60 s clock skew
on token expiry.

## Tests

Do not call `oauth.vocdoni.org` from tests: mount the app with a fake
provider (see `node/test/fakeop.ts` in `vocdoni/oauth`) or test handlers with
a stubbed `req.user`.
