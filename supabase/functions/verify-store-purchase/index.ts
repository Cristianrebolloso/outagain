import { readPayload, recordTransaction, reply, serverClient, verifyTransaction } from "../_shared/store-purchases.ts";

Deno.serve(async req => {
  if (req.method !== "POST") return reply(405, "Method not allowed");
  const token = req.headers.get("Authorization")?.match(/^Bearer (.+)$/i)?.[1];
  if (!token) return reply(401, "Sign in to restore your purchase");
  const { data: { user }, error } = await serverClient().auth.getUser(token);
  if (error || !user) return reply(401, "Sign in to restore your purchase");
  let transaction;
  try {
    const payload = await readPayload(req);
    if (typeof payload.signedTransaction !== "string") return reply(400, "Missing signed transaction");
    transaction = await verifyTransaction(payload.signedTransaction);
  } catch { return reply(400, "Apple could not verify this purchase"); }
  if (transaction.appAccountToken?.toLowerCase() !== user.id.toLowerCase()) {
    return reply(403, "Sign in to the Out Again account used to purchase this item");
  }
  try {
    await recordTransaction(transaction, user.id);
    return reply(200, "Purchase restored");
  } catch { return reply(503, "Your purchase is saved with Apple. Please restore purchases to finish syncing it"); }
});
