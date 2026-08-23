/**
 * Exact port of the Flutter `normalizeName` in
 * `lib/features/structured_actions/utils/name_normalize.dart`.
 *
 * This has to stay byte-for-byte equivalent: every `clientNameLower` written by
 * the agent is matched against rows the app wrote with the Dart version, and the
 * server's own `normalizeClientNameKey` is NOT the same function (it only
 * lowercases and collapses whitespace, so "Rohan ka" would keep the particle and
 * never match).
 */

/** Filler particles dropped as whole tokens. Mirrors `kNameStopParticles`. */
export const NAME_STOP_PARTICLES: ReadonlySet<string> = new Set([
  "se",
  "ka",
  "ki",
  "ke",
  "k",
  "ko",
  "mr",
  "mrs",
  "ms",
  "shri",
  "sri",
  "from",
  "the",
  "a",
  "an",
  "wala",
  "wali",
]);

/** Lowercase, trim, drop particles (whole-token), collapse spaces. */
export function normalizeName(raw: string | null | undefined): string {
  if (raw == null) {
    return "";
  }
  const s = raw.toLowerCase().trim();
  if (!s) {
    return "";
  }
  const parts = s.split(/\s+/);
  const out: string[] = [];
  for (const p of parts) {
    const t = p.replace(/^[.,!]+|[.,!]+$/g, "");
    if (!t) {
      continue;
    }
    if (NAME_STOP_PARTICLES.has(t)) {
      continue;
    }
    out.push(t);
  }
  return out.join(" ").trim();
}

/** Title-cases each word for display, e.g. "rohan traders" → "Rohan Traders". */
export function capitalizeWords(raw: string): string {
  const t = raw.trim().replace(/\s+/g, " ");
  if (!t) {
    return t;
  }
  return t
    .split(" ")
    .map((w) => (w.length > 0 ? w[0]!.toUpperCase() + w.slice(1) : w))
    .join(" ");
}
