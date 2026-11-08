import assert from "node:assert/strict"
import { afterEach, test } from "node:test"

globalThis.Deno = { env: { get: (key) => ({
  SUPABASE_URL: "https://test.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "server-only-test-key",
  SUPABASE_ANON_KEY: "public-test-key",
})[key] } }
const { handleSignIn } = await import("./index.ts")
const originalFetch = globalThis.fetch
afterEach(() => { globalThis.fetch = originalFetch })
const request = (body) => new Request("https://test.supabase.co/functions/v1/sign-in", {
  method: "POST", headers: { "Content-Type": "application/json", "x-forwarded-for": "192.0.2.1" },
  body: JSON.stringify(body),
})
const response = (body, status = 200) => new Response(JSON.stringify(body), { status })

function backend({ found = true, authStatus = 200, allowed = true, limitFailure = false } = {}) {
  const calls = []
  globalThis.fetch = async (url, options) => {
    const parsed = new URL(url)
    calls.push({ url: parsed, options })
    if (parsed.pathname.endsWith("consume_username_signin_attempt")) return response(allowed, limitFailure ? 503 : 200)
    if (parsed.pathname.endsWith("/profiles")) return response(found ? [{ id: "account-id" }] : [])
    if (parsed.pathname.endsWith("/admin/users/account-id")) return response({ email: "private@example.com" })
    if (parsed.pathname.endsWith("/token")) return response(authStatus === 200 ? { access_token: "test-session", user: { id: "account-id" } } : { msg: "internal auth error" }, authStatus)
    throw new Error(`Unexpected request: ${parsed.pathname}`)
  }
  return calls
}

test("normalizes a username and returns only a password-verified session", async () => {
  const calls = backend()
  const result = await handleSignIn(request({ username: "  @CrIsTiAn  ", password: "correct-password" }))
  assert.equal(result.status, 200)
  const body = await result.json()
  assert.equal(body.access_token, "test-session")
  assert.equal(result.headers.get("cache-control"), "no-store")
  assert.equal(calls.find((c) => c.url.pathname.endsWith("/profiles")).url.searchParams.get("username"), "eq.cristian")
  const auth = calls.find((c) => c.url.pathname.endsWith("/token"))
  assert.deepEqual(JSON.parse(auth.options.body), { email: "private@example.com", password: "correct-password" })
  assert.equal(auth.options.headers.apikey, "public-test-key")
  assert.ok(!JSON.stringify(body).includes("private@example.com"))
  assert.ok(!JSON.stringify(body).includes("server-only-test-key"))
})

test("unknown username and wrong password have identical failure responses", async () => {
  backend({ authStatus: 400 })
  const wrong = await handleSignIn(request({ username: "cristian", password: "wrong" }))
  const calls = backend({ found: false, authStatus: 400 })
  const missing = await handleSignIn(request({ username: "unknown", password: "wrong" }))
  assert.equal(wrong.status, missing.status)
  assert.equal(await wrong.text(), await missing.text())
  const authBody = JSON.parse(calls.find((c) => c.url.pathname.endsWith("/token")).options.body)
  assert.notEqual(authBody.password, "wrong")
  assert.match(authBody.email, /@invalid\.example$/)
})

test("rate limits stop lookup and do not reveal the account", async () => {
  const calls = backend({ allowed: false })
  const result = await handleSignIn(request({ username: "cristian", password: "password" }))
  assert.equal(result.status, 429)
  assert.equal(calls.length, 2)
  for (const call of calls) assert.match(JSON.parse(call.options.body).key_hash, /^[a-f0-9]{64}$/)
})

test("rate limiter outages fail closed before lookup", async () => {
  const calls = backend({ limitFailure: true })
  assert.equal((await handleSignIn(request({ username: "cristian", password: "password" }))).status, 503)
  assert.equal(calls.length, 2)
})

test("rejects invalid inputs, malformed JSON, and oversized bodies before lookup", async () => {
  const calls = backend()
  for (const body of [null, {}, { username: "ab", password: "secret" }, { username: "a,b", password: "secret" }, { username: "valid", password: "" }, { username: "valid", password: "x".repeat(9000) }]) {
    assert.equal((await handleSignIn(request(body))).status, 400)
  }
  assert.equal((await handleSignIn(new Request("https://test/", { method: "POST", body: "{" }))).status, 400)
  assert.equal(calls.length, 0)
})

test("upstream throttle and outages preserve retryable status without leaking errors", async () => {
  for (const [authStatus, expected] of [[429, 429], [500, 503]]) {
    backend({ authStatus })
    const result = await handleSignIn(request({ username: "cristian", password: "password" }))
    assert.equal(result.status, expected)
    assert.ok(!(await result.text()).includes("internal auth error"))
  }
})
