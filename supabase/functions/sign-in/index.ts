// Username/password sign-in is intentionally public: the password is verified
// by Supabase Auth before a session can be returned. Service credentials and
// resolved email addresses stay on the server. Never log this request's body.
const headers = {
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const invalidCredentials = () => json({ error: "Invalid username or password." }, 400)
const unavailable = () => json({ error: "Couldn't sign in right now. Please try again." }, 503)
const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers })

export async function handleSignIn(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return new Response("ok", { headers })
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405)
  if (Number(request.headers.get("content-length")) > 8192) return invalidCredentials()

  try {
    // Bound streamed input too: content-length can be absent or forged.
    const reader = request.body?.getReader()
    if (!reader) return invalidCredentials()
    const chunks: Uint8Array[] = []
    let size = 0
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.length
      if (size > 8192) { await reader.cancel(); return invalidCredentials() }
      chunks.push(value)
    }
    const bytes = new Uint8Array(size)
    let offset = 0
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
    let payload: Record<string, unknown>
    try { payload = JSON.parse(new TextDecoder().decode(bytes)) } catch { return invalidCredentials() }
    if (!payload || typeof payload.username !== "string" || typeof payload.password !== "string") return invalidCredentials()
    const username = payload.username.trim().toLowerCase().replace(/^@/, "")
    const password = payload.password
    if (!/^[\p{L}\p{N}_]{3,20}$/u.test(username) || !password || password.length > 4096) return invalidCredentials()

    const url = Deno.env.get("SUPABASE_URL")!
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!
    if (!url || !serviceKey || !anonKey) return unavailable()
    const adminHeaders = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" }

    // Durable, atomic limits apply before any account lookup. Separate keys
    // prevent concurrent isolates or rotating IP addresses bypassing limits.
    const ip = request.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown"
    const limits = await Promise.all([
      consumeLimit(url, adminHeaders, `username:${username}`, 20),
      consumeLimit(url, adminHeaders, `ip:${ip}`, 60),
    ])
    if (limits.some((value) => value === null)) return unavailable()
    if (limits.some((value) => !value)) return json({ error: "Too many sign-in attempts. Try again in five minutes." }, 429)

    const profileURL = new URL(`${url}/rest/v1/profiles`)
    profileURL.search = new URLSearchParams({ select: "id", username: `eq.${username}`, limit: "1" }).toString()
    const profileResponse = await fetch(profileURL, { headers: adminHeaders })
    if (!profileResponse.ok) return unavailable()
    const profiles: { id: string }[] = await profileResponse.json()
    let email: string | undefined
    if (profiles[0]) {
      const userResponse = await fetch(`${url}/auth/v1/admin/users/${profiles[0].id}`, { headers: adminHeaders })
      if (!userResponse.ok) return unavailable()
      const user: { email?: string } = await userResponse.json()
      email = user.email
    }

    // Unknown usernames also attempt a password grant, with a fresh random
    // password. Both paths return the same status and message on rejection.
    const authResponse = await fetch(`${url}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: { apikey: anonKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email: email ?? `missing-${crypto.randomUUID()}@invalid.example`, password: email ? password : crypto.randomUUID() }),
    })
    if (authResponse.status === 429) return json({ error: "Too many sign-in attempts. Try again in five minutes." }, 429)
    if (authResponse.status >= 500) return unavailable()
    if (!authResponse.ok) return invalidCredentials()
    return json(await authResponse.json(), 200)
  } catch {
    // Avoid leaking lookup errors or sensitive credentials in logs/responses.
    return unavailable()
  }
}

async function consumeLimit(url: string, headers: Record<string, string>, key: string, limit: number): Promise<boolean | null> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key))
  const hash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
  const response = await fetch(`${url}/rest/v1/rpc/consume_username_signin_attempt`, {
    method: "POST", headers, body: JSON.stringify({ key_hash: hash, attempt_limit: limit }),
  })
  return response.ok ? await response.json() : null
}

if (import.meta.main) Deno.serve(handleSignIn)
