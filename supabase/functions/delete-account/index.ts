import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
}

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" }

type StoragePathRow = { image_path: string | null }
type BanProfileRow = { is_banned: boolean | null }
type BannedUserRow = { user_id: string; email_hash: string | null }

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

  const token = authHeader.slice("Bearer ".length).trim()
  if (!token) {
    return json({ error: "Missing bearer token" }, 401)
  }

  const supabaseUrl = required("SUPABASE_URL")
  const serviceRoleKey = required("SUPABASE_SERVICE_ROLE_KEY")

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const {
    data: { user },
    error: userError,
  } = await admin.auth.getUser(token)

  if (userError || !user) {
    return json({ error: userError?.message ?? "Invalid JWT" }, 401)
  }

  const banStatus = await fetchBanStatus(admin, user.id, user.email ?? null)
  if (banStatus.error) {
    return json({ error: banStatus.error }, 500)
  }
  if (banStatus.isBanned) {
    return json({ error: "Banned accounts cannot self-delete." }, 403)
  }

  const avatarPaths = await listAvatarPaths(admin, user.id)
  const postImagePaths = await fetchImagePaths(admin, "posts", "author_id", user.id)
  const commentImagePaths = await fetchImagePaths(admin, "comments", "author_id", user.id)
  const momentPaths = uniqueNonEmpty([...postImagePaths, ...commentImagePaths])

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id, false)
  if (deleteError) {
    return json({ error: deleteError.message }, 500)
  }

  const cleanupWarnings: string[] = []

  if (avatarPaths.length > 0) {
    const { error } = await admin.storage.from("avatars").remove(avatarPaths)
    if (error) {
      cleanupWarnings.push(`avatars: ${error.message}`)
    }
  }

  if (momentPaths.length > 0) {
    const { error } = await admin.storage.from("moments").remove(momentPaths)
    if (error) {
      cleanupWarnings.push(`moments: ${error.message}`)
    }
  }

  return json(
    {
      deletedUserId: user.id,
      cleanupWarnings,
    },
    200,
  )
})

async function fetchBanStatus(
  admin: ReturnType<typeof createClient>,
  userId: string,
  email: string | null,
): Promise<{ isBanned: boolean; error?: string }> {
  const { data: profileData, error: profileError } = await admin
    .from("profiles")
    .select("is_banned")
    .eq("id", userId)
    .limit(1)

  if (profileError) {
    console.error("delete-account: profile ban lookup failed", profileError.message)
    return { isBanned: false, error: "Could not verify account moderation status." }
  }

  if (((profileData ?? []) as BanProfileRow[])[0]?.is_banned === true) {
    return { isBanned: true }
  }

  const { data: bannedUserData, error: bannedUserError } = await admin
    .from("banned_users")
    .select("user_id,email_hash")
    .eq("user_id", userId)
    .limit(1)

  if (bannedUserError) {
    console.error("delete-account: banned user lookup failed", bannedUserError.message)
    return { isBanned: false, error: "Could not verify account moderation status." }
  }

  if (((bannedUserData ?? []) as BannedUserRow[]).length > 0) {
    return { isBanned: true }
  }

  const emailHash = await normalizedEmailHash(email)
  if (!emailHash) {
    return { isBanned: false }
  }

  const { data: bannedEmailData, error: bannedEmailError } = await admin
    .from("banned_users")
    .select("user_id,email_hash")
    .eq("email_hash", emailHash)
    .limit(1)

  if (bannedEmailError) {
    console.error("delete-account: banned email lookup failed", bannedEmailError.message)
    return { isBanned: false, error: "Could not verify account moderation status." }
  }

  return { isBanned: ((bannedEmailData ?? []) as BannedUserRow[]).length > 0 }
}

async function listAvatarPaths(
  admin: ReturnType<typeof createClient>,
  userId: string,
): Promise<string[]> {
  const prefix = `users/${userId}`
  const paths: string[] = []
  let offset = 0
  const pageSize = 100

  while (true) {
    const { data, error } = await admin.storage
      .from("avatars")
      .list(prefix, { limit: pageSize, offset })

    if (error) {
      console.error("delete-account: avatar list failed", error.message)
      break
    }

    const batch = data ?? []
    for (const entry of batch) {
      if (entry?.name) {
        paths.push(`${prefix}/${entry.name}`)
      }
    }

    if (batch.length < pageSize) {
      break
    }
    offset += pageSize
    if (offset >= 2000) {
      break
    }
  }

  return paths
}

async function fetchImagePaths(
  admin: ReturnType<typeof createClient>,
  table: "posts" | "comments",
  ownerColumn: "author_id",
  userId: string,
): Promise<string[]> {
  const { data, error } = await admin
    .from(table)
    .select("image_path")
    .eq(ownerColumn, userId)
    .limit(5000)

  if (error) {
    console.error(`delete-account: ${table} lookup failed`, error.message)
    return []
  }

  return uniqueNonEmpty(((data ?? []) as StoragePathRow[]).map((row) => row.image_path))
}

function uniqueNonEmpty(values: Array<string | null | undefined>): string[] {
  return Array.from(
    new Set(
      values
        .map((value) => value?.trim() ?? "")
        .filter((value) => value.length > 0),
    ),
  )
}

async function normalizedEmailHash(email: string | null): Promise<string | null> {
  const normalized = email?.trim().toLowerCase() ?? ""
  if (!normalized) {
    return null
  }

  const data = new TextEncoder().encode(normalized)
  const digest = await crypto.subtle.digest("SHA-256", data)
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
}

function required(name: string): string {
  const value = Deno.env.get(name)
  if (!value) {
    throw new Error(`Missing required env: ${name}`)
  }
  return value
}

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: jsonHeaders,
  })
}
