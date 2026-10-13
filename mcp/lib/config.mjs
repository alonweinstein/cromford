// Operator settings, read once at startup. Nothing here has a default address,
// owner or repo: an unset URL is a startup error, an unset credential is null.
export class ConfigError extends Error {}

const optional = (v) => {
  const s = (v ?? '').trim();
  return s === '' ? null : s;
};

export function loadConfig(env) {
  const raw = optional(env.HARNESS_CONSOLE_URL);
  if (!raw) throw new ConfigError('HARNESS_CONSOLE_URL is not set');
  let u;
  try { u = new URL(raw); } catch { throw new ConfigError('HARNESS_CONSOLE_URL is not a valid URL'); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    throw new ConfigError('HARNESS_CONSOLE_URL must be http or https');
  }
  return {
    url: raw.replace(/\/+$/, ''),
    token: optional(env.HARNESS_CONSOLE_TOKEN),
    secret: optional(env.HARNESS_CONSOLE_SECRET),
    allowlist: (env.HARNESS_MCP_REPO_ALLOWLIST ?? '')
      .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean),
  };
}
