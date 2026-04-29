import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
}

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" }

type ProfileRow = { avatar_path: string | null }
type StoragePathRow = { image_path: string | null }

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

  const avatarPath = await fetchAvatarPath(admin, user.id)
  const postImagePaths = await fetchImagePaths(admin, "posts", "author_id", user.id)
  const commentImagePaths = await fetchImagePaths(admin, "comments", "author_id", user.id)
  const momentPaths = uniqueNonEmpty([...postImagePaths, ...commentImagePaths])

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id, false)
  if (deleteError) {
    return json({ error: deleteError.message }, 500)
  }

  const cleanupWarnings: string[] = []

  if (avatarPath) {
    const { error } = await admin.storage.from("avatars").remove([avatarPath])
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

async function fetchAvatarPath(
  admin: ReturnType<typeof createClient>,
  userId: string,
): Promise<string | null> {
  const { data, error } = await admin
    .from("profiles")
    .select("avatar_path")
    .eq("id", userId)
    .limit(1)

  if (error) {
    console.error("delete-account: avatar lookup failed", error.message)
    return null
  }

  return (((data ?? []) as ProfileRow[])[0]?.avatar_path) ?? null
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
