import { Buffer } from "node:buffer";
import { Environment, SignedDataVerifier, type JWSTransactionDecodedPayload } from "npm:@apple/app-store-server-library@3.1.0";
import { createClient } from "npm:@supabase/supabase-js@2.119.0";
import { APPLE_ROOT_CERTIFICATES } from "./apple-roots.ts";

export const BUNDLE_ID = "com.cristian.OutAgain";
export const subscriptions = new Set([`${BUNDLE_ID}.plus.monthly`, `${BUNDLE_ID}.plus.yearly`]);
export const productIDs = new Set([...subscriptions, ...["night", "orange", "green", "pink", "blue"].map(name => `${BUNDLE_ID}.background.${name}`)]);
const roots = APPLE_ROOT_CERTIFICATES.map(cert => Buffer.from(cert, "base64"));
const verifiers = [Environment.PRODUCTION, Environment.SANDBOX].map(environment =>
  new SignedDataVerifier(roots, true, environment, BUNDLE_ID, 6763454742));

export function serverClient() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function verifyTransaction(jws: string) {
  for (const verifier of verifiers) {
    try { return await verifier.verifyAndDecodeTransaction(jws); } catch { /* Try the other Apple environment. */ }
  }
  throw new Error("Apple transaction verification failed");
}

export async function verifyNotification(jws: string) {
  for (const verifier of verifiers) {
    try { return await verifier.verifyAndDecodeNotification(jws); } catch { /* Never accept unsigned data. */ }
  }
  throw new Error("Apple notification verification failed");
}

export function transactionRecord(transaction: JWSTransactionDecodedPayload, expectedUserID?: string, now = Date.now()) {
  const { appAccountToken, originalTransactionId, productId, environment, signedDate, expiresDate, revocationDate } = transaction;
  if (transaction.bundleId !== BUNDLE_ID || !productId || !productIDs.has(productId)) throw new Error("Unknown purchase");
  if (environment !== Environment.PRODUCTION && environment !== Environment.SANDBOX) throw new Error("Invalid environment");
  if (!appAccountToken || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(appAccountToken)) throw new Error("Missing account token");
  if (expectedUserID && appAccountToken.toLowerCase() !== expectedUserID.toLowerCase()) throw new Error("Purchase belongs to another account");
  if (!originalTransactionId || !/^[0-9]{1,40}$/.test(originalTransactionId)) throw new Error("Invalid transaction ID");
  if (!signedDate || !Number.isFinite(signedDate) || signedDate > now + 300_000) throw new Error("Invalid signature date");
  if (subscriptions.has(productId) && (!expiresDate || !Number.isFinite(expiresDate))) throw new Error("Missing subscription expiry");
  if (revocationDate !== undefined && !Number.isFinite(revocationDate)) throw new Error("Invalid revocation date");
  return {
    p_user_id: appAccountToken.toLowerCase(),
    p_original_transaction_id: originalTransactionId,
    p_environment: environment,
    p_product_id: productId,
    p_expires_at: expiresDate ? new Date(expiresDate).toISOString() : null,
    p_revoked_at: revocationDate ? new Date(revocationDate).toISOString() : null,
    p_signed_at: new Date(signedDate).toISOString(),
  };
}

export async function recordTransaction(transaction: JWSTransactionDecodedPayload, expectedUserID?: string) {
  const record = transactionRecord(transaction, expectedUserID);
  const { error } = await serverClient().rpc("record_verified_store_purchase", record);
  if (error) throw new Error("Purchase could not be saved");
}

export async function readPayload(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > 100_000) throw new Error("Payload too large");
  const data = JSON.parse(text);
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("Invalid payload");
  return data;
}

export function reply(status: number, message: string) {
  return new Response(JSON.stringify({ message }), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}
