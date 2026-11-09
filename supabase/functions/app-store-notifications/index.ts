import { readPayload, recordTransaction, reply, verifyNotification, verifyTransaction } from "../_shared/store-purchases.ts";

// Apple authenticates every notification with its certificate chain and JWS.
// This webhook deliberately does not accept a client JWT as proof of purchase.
Deno.serve(async req => {
  if (req.method !== "POST") return reply(405, "Method not allowed");
  let notification;
  try {
    const payload = await readPayload(req);
    if (typeof payload.signedPayload !== "string") return reply(400, "Missing signed notification");
    notification = await verifyNotification(payload.signedPayload);
  } catch { return reply(400, "Invalid Apple notification"); }
  const signedTransaction = notification.data?.signedTransactionInfo;
  if (!signedTransaction) return reply(200, "Notification acknowledged");
  try {
    const transaction = await verifyTransaction(signedTransaction);
    await recordTransaction(transaction);
    return reply(200, "Notification processed");
  } catch {
    // Apple retries failed deliveries. Never acknowledge a lost renewal/refund.
    return reply(503, "Please retry notification delivery");
  }
});
