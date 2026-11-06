const ADMIN_TIMEOUT_MS = 3_000;

export async function isAdministrator(request: Request): Promise<boolean> {
  const token = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!token || !url || !anonKey) return false;

  const response = await fetch(`${url}/auth/v1/user`, {
    headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(ADMIN_TIMEOUT_MS),
  }).catch(() => null);
  const user = response?.ok
    ? await response.json().catch(() => null) as {
      id?: unknown;
      email?: unknown;
      email_confirmed_at?: unknown;
      is_anonymous?: unknown;
    } | null
    : null;
  if (!user || typeof user.id !== "string" || !user.id.trim()) return false;
  if (user.is_anonymous === true) return false;
  if (typeof user.email_confirmed_at !== "string" || !user.email_confirmed_at.trim()) return false;
  return isAdministratorEmail(user?.email);
}

export function isAdministratorEmail(value: unknown): boolean {
  if (typeof value !== "string" || !value.trim()) return false;

  const primaryEmail = Deno.env.get("ADMIN_EMAIL") ?? "";
  const additionalEmails = (Deno.env.get("ADMIN_ADDITIONAL_EMAILS") ?? "").split(",");
  const email = value.trim().toLowerCase();
  return [primaryEmail, ...additionalEmails].some((candidate) =>
    candidate.trim().toLowerCase() === email
  );
}
