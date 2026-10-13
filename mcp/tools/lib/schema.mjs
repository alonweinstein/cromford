// The argument check every read and action tool runs as its precheck. The
// tracer's callTool refuses unknown keys; this refuses the rest of what the
// inputSchema declares (required, type, minLength/maxLength, minimum/maximum,
// enum), recursing into nested objects, so a malformed call sends nothing.
// This directory holds no .mjs at the top level, so loadTools never reads it.
const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

const TYPES = {
  object: isPlain,
  string: (v) => typeof v === 'string',
  integer: (v) => Number.isInteger(v),
  number: (v) => typeof v === 'number' && Number.isFinite(v),
  boolean: (v) => typeof v === 'boolean',
};

// The first key path that breaks the schema, or null. Unknown keys are left
// to callTool, which names them the same way.
export function badArg(args, schema, prefix = '') {
  if (!isPlain(args)) return prefix ? prefix.slice(0, -1) : '(arguments)';
  for (const k of schema.required ?? []) if (args[k] === undefined) return prefix + k;
  for (const [k, s] of Object.entries(schema.properties ?? {})) {
    const v = args[k];
    if (v === undefined) continue;
    const p = prefix + k;
    if (s.type && !TYPES[s.type]?.(v)) return p;
    if (s.type === 'object') {
      const nested = badArg(v, s, p + '.');
      if (nested) return nested;
      continue;
    }
    if (typeof v === 'string' &&
      ((s.minLength !== undefined && v.length < s.minLength) ||
       (s.maxLength !== undefined && v.length > s.maxLength))) return p;
    if (typeof v === 'number' &&
      ((s.minimum !== undefined && v < s.minimum) ||
       (s.maximum !== undefined && v > s.maximum))) return p;
    if (s.enum && !s.enum.includes(v)) return p;
  }
  return null;
}

// A precheck for one schema: `invalid_arguments: <path>` or null.
export const checkArgs = (schema) => (args) => {
  const bad = badArg(args, schema);
  return bad ? `invalid_arguments: ${bad}` : null;
};
