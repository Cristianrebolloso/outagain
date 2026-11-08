// Edge function: notify-activity
//
// Receives a push dispatch payload from the `dispatch_notification_push`
// Postgres trigger, looks up the recipient's registered device tokens, mints
// an APNs JWT, and sends an HTTP/2 push to the matching APNs environment for
// each device. Bad-token responses (410 Gone or 400 BadDeviceToken) retire
// the offending row from public.devices.
//
// Environment (set via `supabase secrets set`):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  -- standard edge-function secrets
//   APNS_KEY_ID        -- 10-char key identifier from Apple Developer
//   APNS_TEAM_ID       -- 10-char Apple team identifier
//   APNS_BUNDLE_ID     -- the iOS app's bundle identifier (apns-topic)
//   APNS_KEY_P8        -- the contents of the .p8 key file, including the
//                          -----BEGIN PRIVATE KEY----- markers
//   APNS_ENVIRONMENT   -- "production" (default) or "development"
//
// The function is idempotent: resending the same notificationId produces the
// same push payload. APNs de-dupes via apns-collapse-id.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

type DeliveryRequest = {
  notificationId?: string | null
  recipientUserId?: string | null
  actorUserId?: string | null
  kind?: string | null
  title?: string | null
  body?: string | null
  postId?: string | null
  commentId?: string | null
  nightStart?: string | null
  nightEnd?: string | null
  nightGroupId?: string | null
}

type DeliveryFailure = {
  deviceId: string
  token: string
  status: number
  reason?: string
}

type ApnsEnvironment = "development" | "production"

type PushAttemptClient = {
  from: (table: string) => {
    update: (values: Record<string, unknown>) => {
      eq: (column: string, value: string) => PromiseLike<{ error: { message: string } | null }>
    }
  }
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
}

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" }

// Cache the minted APNs JWT for up to ~50 minutes (APNs requires rotation at
// least every 60 minutes).
type CachedToken = { token: string; expiresAt: number }
let cachedApnsToken: CachedToken | null = null

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405)
  }

  const authHeader = request.headers.get("Authorization") ?? ""
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Missing authorization header" }, 401)
  }

  const supabaseUrl = required("SUPABASE_URL")
  const serviceRoleKey = required("SUPABASE_SERVICE_ROLE_KEY")
  const bearerToken = authHeader.slice(7).trim()

  // This endpoint is internal-only. The database trigger authenticates with
  // the service-role key, and we validate that key here because this function
  // is deployed with gateway JWT verification disabled.
  if (bearerToken != serviceRoleKey) {
    return json({ error: "Unauthorized" }, 401)
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  let payload: DeliveryRequest
  try {
    payload = (await request.json()) as DeliveryRequest
  } catch {
    return json({ error: "Invalid JSON body" }, 400)
  }

  if (!payload.recipientUserId) {
    const responseBody = { error: "recipientUserId required" }
    await recordPushAttempt(admin, payload.notificationId, {
      status: "errored",
      edge_status_code: 400,
      edge_response: responseBody,
      error_message: responseBody.error,
      delivered_count: 0,
      failure_count: 0,
    })
    return json(responseBody, 400)
  }

  // Recheck the account's opt-out immediately before any APNs delivery.
  // Missing rows/values default on; a lookup failure must not bypass opt-outs.
  const [preferenceColumn, disabledReason] = preferenceForKind(payload.kind)
  const { data: preference, error: preferenceError } = await admin
    .from("notification_preferences")
    .select(preferenceColumn)
    .eq("user_id", payload.recipientUserId)
    .maybeSingle()

  if (preferenceError) {
    const responseBody = { error: "Could not check notification preference" }
    await recordPushAttempt(admin, payload.notificationId, {
      status: "errored", edge_status_code: 503, edge_response: responseBody,
      error_message: responseBody.error, delivered_count: 0, failure_count: 0,
    })
    return json(responseBody, 503)
  }
  if (preference?.[preferenceColumn] === false) {
    const responseBody = { delivered: 0, skipped: disabledReason }
    await recordPushAttempt(admin, payload.notificationId, {
      status: "skipped", skip_reason: responseBody.skipped,
      edge_status_code: 200, edge_response: responseBody,
      delivered_count: 0, failure_count: 0,
    })
    return json(responseBody)
  }

  const { data: deviceRows, error: deviceError } = await admin
    .from("devices")
    .select("id, apns_token, environment, last_seen_at")
    .eq("user_id", payload.recipientUserId)

  if (deviceError) {
    const responseBody = { error: deviceError.message }
    await recordPushAttempt(admin, payload.notificationId, {
      status: "errored",
      edge_status_code: 500,
      edge_response: responseBody,
      error_message: deviceError.message,
      delivered_count: 0,
      failure_count: 0,
    })
    return json(responseBody, 500)
  }

  let apnsEnvironment: ApnsEnvironment
  try {
    apnsEnvironment =
      required("APNS_ENVIRONMENT").toLowerCase() === "development"
        ? "development"
        : "production"
  } catch {
    apnsEnvironment = "production"
  }

  const eligibleDeviceRows =
    deviceRows?.filter((row) => row.environment === apnsEnvironment) ?? []

  if (eligibleDeviceRows.length === 0) {
    const responseBody = { delivered: 0, skipped: `no-${apnsEnvironment}-devices` }
    await recordPushAttempt(admin, payload.notificationId, {
      status: "skipped",
      skip_reason: `no-${apnsEnvironment}-devices`,
      edge_status_code: 200,
      edge_response: responseBody,
      delivered_count: 0,
      failure_count: 0,
    })
    return json(responseBody, 200)
  }

  let apnsJwt: string
  try {
    apnsJwt = await getApnsToken()
  } catch (err) {
    const message = `APNs JWT error: ${err instanceof Error ? err.message : String(err)}`
    const responseBody = { error: message }
    await recordPushAttempt(admin, payload.notificationId, {
      status: "errored",
      edge_status_code: 500,
      edge_response: responseBody,
      error_message: message,
      delivered_count: 0,
      failure_count: 0,
    })
    return json(responseBody, 500)
  }

  let bundleId: string
  try {
    bundleId = required("APNS_BUNDLE_ID")
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    const responseBody = { error: message }
    await recordPushAttempt(admin, payload.notificationId, {
      status: "errored",
      edge_status_code: 500,
      edge_response: responseBody,
      error_message: message,
      delivered_count: 0,
      failure_count: 0,
    })
    return json(responseBody, 500)
  }

  // Count unread notifications for the recipient so APNs can set the badge
  // number on the icon even when the app is backgrounded or killed.
  const { count: unreadCount } = await admin
    .from("notifications")
    .select("id", { count: "exact", head: true })
    .eq("user_id", payload.recipientUserId)
    .is("read_at", null)

  const notificationPayload = buildPayload(payload, unreadCount ?? 1)

  let delivered = 0
  const failures: DeliveryFailure[] = []

  await Promise.all(
    eligibleDeviceRows.map(async (row) => {
      const host =
        row.environment === "development"
          ? "https://api.sandbox.push.apple.com"
          : "https://api.push.apple.com"

      const url = `${host}/3/device/${row.apns_token}`
      const headers: Record<string, string> = {
        "authorization": `bearer ${apnsJwt}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      }

      if (payload.notificationId) {
        headers["apns-collapse-id"] = payload.notificationId.slice(0, 64)
      }
      if (payload.kind === "announcement") {
        // A weekend reminder should not arrive days later on an offline phone.
        headers["apns-expiration"] = String(Math.floor(Date.now() / 1000) + 86400)
      }

      try {
        const response = await fetch(url, {
          method: "POST",
          headers,
          body: JSON.stringify(notificationPayload),
        })

        if (response.ok) {
          delivered += 1
          return
        }

        const bodyText = await response.text()
        let reason: string | undefined
        try {
          reason = JSON.parse(bodyText).reason
        } catch {
          reason = bodyText || undefined
        }

        failures.push({
          deviceId: row.id,
          token: maskToken(row.apns_token),
          status: response.status,
          reason,
        })

        // Retire dead tokens per APNs conventions.
        if (
          response.status === 410 ||
          reason === "BadDeviceToken" ||
          reason === "Unregistered"
        ) {
          await admin.from("devices").delete().eq("id", row.id)
        }
      } catch (err) {
        failures.push({
          deviceId: row.id,
          token: maskToken(row.apns_token),
          status: 0,
          reason: err instanceof Error ? err.message : String(err),
        })
      }
    }),
  )

  const responseBody = { delivered, failures }
  const attemptStatus =
    failures.length === 0
      ? "delivered"
      : delivered > 0
        ? "partial"
        : "errored"

  await recordPushAttempt(admin, payload.notificationId, {
    status: attemptStatus,
    edge_status_code: 200,
    edge_response: responseBody,
    error_message:
      failures.length === 0
        ? null
        : delivered > 0
          ? "Some APNs sends failed"
          : "All APNs sends failed",
    skip_reason: null,
    delivered_count: delivered,
    failure_count: failures.length,
  })

  return json(responseBody, 200)
})

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders })
}

function required(name: string): string {
  const value = Deno.env.get(name)
  if (!value) {
    throw new Error(`Missing required env: ${name}`)
  }
  return value
}

async function recordPushAttempt(
  admin: PushAttemptClient,
  notificationId: string | null | undefined,
  patch: Record<string, unknown>,
) {
  if (!notificationId) {
    return
  }

  try {
    const { error } = await admin
      .from("push_attempts")
      .update({
        completed_at: new Date().toISOString(),
        ...patch,
      })
      .eq("notification_id", notificationId)

    if (error) {
      console.error(`push_attempts update failed: ${error.message}`)
    }
  } catch (err) {
    console.error(`push_attempts update failed: ${err instanceof Error ? err.message : String(err)}`)
  }
}

function maskToken(token: string): string {
  if (token.length <= 12) {
    return token
  }
  return `${token.slice(0, 6)}...${token.slice(-6)}`
}

type ApnsAlert = {
  title?: string | null
  body?: string | null
}

function buildPayload(payload: DeliveryRequest, badge: number = 1) {
  // Social alerts are one invitation to open the destination. Announcement
  // bodies are authored messages, so retain their content.
  const alert: ApnsAlert = payload.kind === "announcement"
    ? { title: payload.title ?? undefined, body: payload.body ?? undefined }
    : { title: notificationHeadline(payload.kind, payload.title ?? "") || "New activity" }

  return {
    aps: {
      alert,
      sound: "default",
      badge,
      "thread-id": payload.postId ?? payload.kind ?? "outagain",
      "mutable-content": 1,
    },
    outagain: {
      kind: payload.kind ?? null,
      notificationId: payload.notificationId ?? null,
      postId: payload.postId ?? null,
      commentId: payload.commentId ?? null,
      actorUserId: payload.actorUserId ?? null,
      nightStart: payload.nightStart ?? null,
      nightEnd: payload.nightEnd ?? null,
      nightGroupId: payload.nightGroupId ?? null,
    },
  }
}

// Keep aligned with NotificationCopy.swift for existing and newly queued rows.
function notificationHeadline(kind: DeliveryRequest["kind"], title: string): string {
  title = title.trim()
  if (kind === "nightRecap") return "Last night's photos"

  let replacements: [string, string][]
  switch (kind) {
    case "comment":
      replacements = [
        [" commented on your post", " left a comment on your post!"],
        [" replied to your comment", " replied to your comment!"],
      ]
      break
    case "photoReply":
      replacements = [
        [" commented on your post", " left a photo on your post!"],
        [" replied to your comment", " replied to your comment with a photo!"],
      ]
      break
    case "friendRequest":
      replacements = [[" sent you a friend request", " sent you a friend request!"]]
      break
    case "friendAccepted":
      replacements = [[" accepted your friend request", " accepted your friend request!"]]
      break
    case "commentTagged":
      replacements = [[" mentioned you in a comment", " mentioned you in a comment!"]]
      break
    default:
      return title
  }

  const sentence = title.replace(/[.!]+$/, "")
  for (const [oldEnding, newEnding] of replacements) {
    if (sentence.endsWith(oldEnding)) return sentence.slice(0, -oldEnding.length) + newEnding
  }
  return title
}

async function getApnsToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  if (cachedApnsToken && cachedApnsToken.expiresAt - 60 > now) {
    return cachedApnsToken.token
  }

  const keyId = required("APNS_KEY_ID")
  const teamId = required("APNS_TEAM_ID")
  const p8 = required("APNS_KEY_P8")

  const header = { alg: "ES256", kid: keyId, typ: "JWT" }
  const payload = { iss: teamId, iat: now }

  const encoder = new TextEncoder()
  const headerBytes = encoder.encode(JSON.stringify(header))
  const payloadBytes = encoder.encode(JSON.stringify(payload))

  const signingInput = `${base64url(headerBytes)}.${base64url(payloadBytes)}`

  const keyDer = pemToPkcs8(p8)
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyDer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  )

  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: { name: "SHA-256" } },
      key,
      encoder.encode(signingInput),
    ),
  )

  const token = `${signingInput}.${base64url(signature)}`
  // APNs recommends rotating every ~55 minutes.
  cachedApnsToken = { token, expiresAt: now + 55 * 60 }
  return token
}

function base64url(bytes: Uint8Array | ArrayBuffer): string {
  const input = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let str = ""
  for (let i = 0; i < input.length; i += 1) {
    str += String.fromCharCode(input[i])
  }
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "")

  const binary = atob(body)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes.buffer
}

// Keep this mapping aligned with the categories exposed in Settings.
function preferenceForKind(kind: DeliveryRequest["kind"]): [string, string] {
  switch (kind) {
    case "nightRecap": return ["recaps_enabled", "recaps-disabled"]
    case "announcement": return ["announcements_enabled", "announcements-disabled"]
    case "friendRequest":
    case "friendAccepted": return ["friend_requests_enabled", "friend-requests-disabled"]
    case "reaction":
    case "commentLike": return ["reactions_enabled", "reactions-disabled"]
    case "comment":
    case "photoReply":
    case "commentTagged": return ["comments_enabled", "comments-disabled"]
    default: return ["activity_enabled", "activity-disabled"]
  }
}
