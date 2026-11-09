import { BUNDLE_ID, readPayload, transactionRecord, verifyNotification, verifyTransaction } from "./store-purchases.ts";

const account = "11111111-1111-4111-8111-111111111111";
const now = Date.now();
const valid = {
  appAccountToken: account, originalTransactionId: "1234567890", productId: `${BUNDLE_ID}.plus.monthly`,
  bundleId: BUNDLE_ID, environment: "Production", signedDate: now, expiresDate: now + 86400000,
};
function assert(value: unknown, message = "Assertion failed") { if (!value) throw new Error(message); }
function rejectsSync(action: () => unknown) {
  let threw = false; try { action(); } catch { threw = true; }
  assert(threw, "Invalid transaction accepted");
}

Deno.test("Signed transaction claims must match account, app, product, and dates", () => {
  assert(transactionRecord(valid, account).p_product_id === valid.productId);
  for (const changes of [
    { appAccountToken: undefined }, { appAccountToken: "invalid" }, { bundleId: "another.app" },
    { productId: `${BUNDLE_ID}.background.standard` }, { environment: "Xcode" },
    { originalTransactionId: "" }, { signedDate: now + 600000 }, { expiresDate: undefined },
    { expiresDate: NaN }, { revocationDate: Infinity },
  ]) rejectsSync(() => transactionRecord({ ...valid, ...changes }, account, now));
  rejectsSync(() => transactionRecord(valid, "22222222-2222-4222-8222-222222222222", now));
});

Deno.test("Permanent backgrounds have no expiry; refunds and expired subscriptions reach the database", () => {
  const background = transactionRecord({ ...valid, productId: `${BUNDLE_ID}.background.blue`, expiresDate: undefined });
  assert(background.p_expires_at === null);
  assert(transactionRecord({ ...valid, expiresDate: now - 1 }).p_expires_at !== null);
  assert(transactionRecord({ ...valid, revocationDate: now }).p_revoked_at !== null);
  assert(transactionRecord({ ...valid, environment: "Sandbox" }).p_environment === "Sandbox");
});

Deno.test("Forged JWS transactions and notifications never pass Apple verification", async () => {
  const forged = btoa(JSON.stringify({ alg: "none" })) + "." + btoa(JSON.stringify(valid)) + ".";
  for (const verifier of [verifyTransaction, verifyNotification]) {
    let rejected = false;
    try { await verifier(forged); } catch { rejected = true; }
    assert(rejected, "Unsigned purchase accepted");
  }
});

Deno.test("Reject malformed and oversized request bodies", async () => {
  for (const body of ["null", "[]", "not json", "x".repeat(100001)]) {
    let rejected = false;
    try { await readPayload(new Request("https://example.invalid", { method: "POST", body })); } catch { rejected = true; }
    assert(rejected);
  }
});
