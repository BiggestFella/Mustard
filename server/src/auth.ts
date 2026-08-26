// Bearer-token auth for the single-user task service (ADR-0013).
// Tokens are long random strings; only their SHA-256 hex digest is stored
// (clients.token_hash), so the lookup itself is the verification and no
// plaintext comparison ever happens server-side.

export type ClientScope = "user_app" | "worker";

export interface AuthedClient {
  id: string;
  name: string;
  kind: ClientScope;
  provider: string | null;
  enabled: boolean;
}

export async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function bearerToken(authorizationHeader: string | undefined): string | null {
  if (!authorizationHeader) return null;
  const match = /^Bearer\s+(\S+)$/.exec(authorizationHeader);
  const token = match?.[1] ?? null;
  // Refuse trivially short tokens outright; real ones are 40+ chars.
  return token && token.length >= 32 ? token : null;
}

// Route-level authorization. user_app can do everything; worker is limited to
// the claim/execute/report loop. Review decisions, provider assignment,
// deletion, and client administration are user-only.
const workerAllowed = new Set([
  "tasks.list",
  "tasks.get",
  "tasks.claim",
  "leases.renew",
  "leases.release",
  "messages.append",
  "outcome.report",
  "artifacts.create",
  "artifacts.download",
  "events.list",
  "me",
  "health",
]);

export function isAllowed(scope: ClientScope, permission: string): boolean {
  if (scope === "user_app") return true;
  return workerAllowed.has(permission);
}
