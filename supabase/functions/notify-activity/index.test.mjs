import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { stripTypeScriptTypes } from 'node:module'
import { afterEach, test } from 'node:test'

// Load the deployed handler with only its runtime and database adapters mocked.
// No external network calls or real APNs credentials are used by these tests.
let handler
let database
let env = { SUPABASE_URL: 'https://test.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'test-server-key' }
globalThis.Deno = { env: { get: key => env[key] }, serve: fn => { handler = fn } }
globalThis.__pushTestClient = () => database
let source = await readFile(new URL('./index.ts', import.meta.url), 'utf8')
source = source.replace('import "jsr:@supabase/functions-js/edge-runtime.d.ts"', '')
source = source.replace('import { createClient } from "npm:@supabase/supabase-js@2"', 'const createClient = globalThis.__pushTestClient')
await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`)
const originalFetch = globalThis.fetch
afterEach(() => { globalThis.fetch = originalFetch })
function mockDB({ preference = null, preferenceError = null, devices = [] } = {}) {
  const tables = [], attempts = [], deletes = []
  database = { from(table) {
    tables.push(table)
    const query = {
      select() { return query }, eq() { return query }, is() { return query },
      maybeSingle: async () => ({ data: preference, error: preferenceError }),
      update(values) { attempts.push(values); return query },
      delete() { deletes.push(table); return query },
      then(resolve) { return Promise.resolve({ data: table === 'devices' ? devices : null, count: 2, error: null }).then(resolve) },
    }
    return query
  } }
  return { tables, attempts, deletes }
}
const request = (kind = 'announcement', token = 'test-server-key') => new Request('https://test/notify', {
  method: 'POST', headers: { Authorization: `Bearer ${token}` },
  body: JSON.stringify({ notificationId: 'notification-id', recipientUserId: 'recipient-id', kind, title: 'Friday 🎉', body: 'See you tonight!' }),
})

test('rejects a non-service caller before any data access', async () => {
  const db = mockDB()
  assert.equal((await handler(request('announcement', 'user-token'))).status, 401)
  assert.deepEqual(db.tables, [])
})
test('an opt-out after queueing stops delivery before device or APNs access', async () => {
  const db = mockDB({ preference: { announcements_enabled: false } })
  const response = await handler(request())
  assert.deepEqual(await response.json(), { delivered: 0, skipped: 'announcements-disabled' })
  assert.ok(!db.tables.includes('devices'))
  assert.equal(db.attempts[0].status, 'skipped')
})
test('unavailable preference fails closed', async () => {
  const db = mockDB({ preferenceError: { message: 'offline' } })
  assert.equal((await handler(request())).status, 503)
  assert.ok(!db.tables.includes('devices'))
  assert.equal(db.attempts[0].status, 'errored')
})
test('existing users without a preference remain enabled', async () => {
  const db = mockDB()
  assert.equal((await handler(request())).status, 200)
  assert.ok(db.tables.includes('devices'))
  assert.equal(db.attempts[0].skip_reason, 'no-production-devices')
})
test('social pushes do not use the announcements preference', async () => {
  const db = mockDB({ preference: { announcements_enabled: false } })
  assert.equal((await handler(request('comment'))).status, 200)
  assert.ok(db.tables.includes('notification_preferences'))
  assert.ok(db.tables.includes('devices'))
})
const socialCategories = [
  ["recaps_enabled", "recaps-disabled", ["nightRecap"]],
  ['friend_requests_enabled', 'friend-requests-disabled', ['friendRequest', 'friendAccepted']],
  ['reactions_enabled', 'reactions-disabled', ['reaction', 'commentLike']],
  ['comments_enabled', 'comments-disabled', ['comment', 'photoReply', 'commentTagged']],
  ['activity_enabled', 'activity-disabled', ['tagged', 'groupAdded', 'profileVerified', 'friendPost', 'futureKind']],
]
for (const [column, reason, kinds] of socialCategories) {
  for (const kind of kinds) {
    test(`${kind} is enabled by default and respects its own opt-out`, async () => {
      let db = mockDB()
      assert.equal((await handler(request(kind))).status, 200)
      assert.ok(db.tables.includes('devices'))
      db = mockDB({ preference: { [column]: false } })
      assert.deepEqual(await (await handler(request(kind))).json(), { delivered: 0, skipped: reason })
      assert.ok(!db.tables.includes('devices'))
      assert.equal(db.attempts[0].status, 'skipped')
      db = mockDB({ preferenceError: { message: 'offline' } })
      assert.equal((await handler(request(kind))).status, 503)
      assert.ok(!db.tables.includes('devices'))
    })
  }
}
test('disabling social activity does not suppress announcements', async () => {
  const db = mockDB({ preference: {
    friend_requests_enabled: false, reactions_enabled: false, comments_enabled: false, activity_enabled: false,
  } })
  assert.equal((await handler(request())).status, 200)
  assert.ok(db.tables.includes('devices'))
})
test('authorized push has the custom alert, routing, expiry and delivery receipt', async () => {
  const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', key.privateKey)
  env = { ...env, APNS_KEY_ID: 'TESTKEY', APNS_TEAM_ID: 'TESTTEAM', APNS_BUNDLE_ID: 'test.outagain',
    APNS_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${Buffer.from(pkcs8).toString('base64')}\n-----END PRIVATE KEY-----` }
  const db = mockDB({ preference: { announcements_enabled: true }, devices: [
    { id: 'device', apns_token: 'test-device-token', environment: 'production' },
    { id: 'dev-device', apns_token: 'development-token', environment: 'development' },
  ] })
  const sends = []
  globalThis.fetch = async (url, options) => { sends.push({ url, options }); return new Response('', { status: 200 }) }
  const result = await handler(request())
  assert.equal((await result.json()).delivered, 1)
  assert.equal(sends.length, 1)
  assert.equal(sends[0].url, 'https://api.push.apple.com/3/device/test-device-token')
  const payload = JSON.parse(sends[0].options.body)
  assert.deepEqual(payload.aps.alert, { title: 'Friday 🎉', body: 'See you tonight!' })
  assert.equal(payload.outagain.kind, 'announcement')
  assert.equal(payload.outagain.notificationId, 'notification-id')
  assert.equal(sends[0].options.headers['apns-collapse-id'], 'notification-id')
  assert.ok(Number(sends[0].options.headers['apns-expiration']) > Date.now() / 1000)
  assert.ok(Buffer.byteLength(sends[0].options.body) < 4096)
  assert.equal(db.attempts[0].delivered_count, 1)
  const route = { kind: 'nightRecap', nightStart: '2026-10-26T12:00:00+00:00', nightEnd: '2026-10-27T12:00:00+00:00', nightGroupId: 'group-id' }
  const recap = new Request('https://test/notify', { method: 'POST', headers: { Authorization: 'Bearer test-server-key' },
    body: JSON.stringify({ ...route, notificationId: 'recap-id', recipientUserId: 'recipient-id', title: "Last night's photos", body: '3 photos' }) })
  assert.equal((await (await handler(recap)).json()).delivered, 1)
  const recapPayload = JSON.parse(sends[1].options.body)
  for (const [key, value] of Object.entries(route)) assert.equal(recapPayload.outagain[key], value)
  assert.equal(sends[1].options.headers['apns-collapse-id'], 'recap-id')
})
test('invalid device token is retired and failure is recorded', async () => {
  const db = mockDB({ devices: [{ id: 'device', apns_token: 'bad-token', environment: 'production' }] })
  globalThis.fetch = async () => new Response(JSON.stringify({ reason: 'Unregistered' }), { status: 410 })
  const result = await handler(request())
  assert.equal((await result.json()).delivered, 0)
  assert.deepEqual(db.deletes, ['devices'])
  assert.equal(db.attempts[0].failure_count, 1)
})

test('social alerts use one headline while keeping badges and destinations', async () => {
  const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', key.privateKey)
  env = { ...env, APNS_KEY_ID: 'TESTKEY', APNS_TEAM_ID: 'TESTTEAM', APNS_BUNDLE_ID: 'test.outagain',
    APNS_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${Buffer.from(pkcs8).toString('base64')}\n-----END PRIVATE KEY-----` }
  const fixtures = JSON.parse(await readFile(new URL('../../../scripts/fixtures/notification-copy.json', import.meta.url), 'utf8'))
  const sends = []
  globalThis.fetch = async (_, options) => { sends.push(JSON.parse(options.body)); return new Response('', { status: 200 }) }
  for (const fixture of fixtures.filter(item => item.kind !== 'announcement')) {
    mockDB({ devices: [{ id: 'device', apns_token: 'test-device-token', environment: 'production' }] })
    const route = { kind: fixture.kind, notificationId: 'notification-id', actorUserId: 'actor-id',
      postId: 'post-id', commentId: 'comment-id', nightStart: '2026-11-01T12:00:00Z', nightEnd: '2026-11-02T12:00:00Z', nightGroupId: 'group-id' }
    const response = await handler(new Request('https://test/notify', {
      method: 'POST', headers: { Authorization: 'Bearer test-server-key' },
      body: JSON.stringify({ ...route, recipientUserId: 'recipient-id', title: fixture.title,
        body: 'This secondary copy must not appear on the Lock Screen.' }),
    }))
    assert.equal((await response.json()).delivered, 1)
    const payload = sends.at(-1)
    assert.deepEqual(payload.aps.alert, { title: fixture.expected }, fixture.kind)
    assert.equal(payload.aps.badge, 2)
    assert.equal(payload.aps.sound, 'default')
    assert.equal(payload.aps['thread-id'], 'post-id')
    assert.deepEqual(payload.outagain, route)
  }
})
