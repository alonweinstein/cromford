// SPDX-License-Identifier: Apache-2.0
// validate: a minimal JSON Schema subset. A keyword outside the subset throws,
// so a schema is never enforced partly in silence.

const SUPPORTED = new Set([
  'type', 'required', 'properties', 'additionalProperties', 'enum', 'items',
  'minLength', 'minItems', 'minimum', 'pattern',
  '$schema', '$id', 'title', 'description',
]);

function assertSupported(schema) {
  if (schema === null || typeof schema !== 'object' || Array.isArray(schema)) throw new TypeError('validate: a schema must be an object');
  for (const k of Object.keys(schema)) if (!SUPPORTED.has(k)) throw new Error(`unsupported keyword ${k}`);
  if (typeof schema.additionalProperties !== 'undefined' && typeof schema.additionalProperties !== 'boolean') {
    throw new Error('unsupported keyword additionalProperties (only a boolean is supported)');
  }
  for (const sub of Object.values(schema.properties || {})) assertSupported(sub);
  if (schema.items !== undefined) assertSupported(schema.items);
}

function typeOk(type, v) {
  switch (type) {
    case 'object': return v !== null && typeof v === 'object' && !Array.isArray(v);
    case 'array': return Array.isArray(v);
    case 'string': return typeof v === 'string';
    case 'integer': return Number.isInteger(v);
    case 'number': return typeof v === 'number' && Number.isFinite(v);
    case 'boolean': return typeof v === 'boolean';
    case 'null': return v === null;
    default: throw new Error(`unsupported type ${type}`);
  }
}

function check(schema, v, path, errors) {
  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => typeOk(t, v))) { errors.push(`${path}: expected ${types.join('|')}`); return; }
  }
  if (schema.enum !== undefined && !schema.enum.some((e) => e === v)) errors.push(`${path}: not one of ${schema.enum.join(', ')}`);
  if (typeof v === 'string') {
    if (schema.minLength !== undefined && v.length < schema.minLength) errors.push(`${path}: shorter than ${schema.minLength}`);
    if (schema.pattern !== undefined && !new RegExp(schema.pattern, 'u').test(v)) errors.push(`${path}: does not match ${schema.pattern}`);
  }
  if (typeof v === 'number' && schema.minimum !== undefined && v < schema.minimum) errors.push(`${path}: less than ${schema.minimum}`);
  if (Array.isArray(v)) {
    if (schema.minItems !== undefined && v.length < schema.minItems) errors.push(`${path}: fewer than ${schema.minItems} items`);
    if (schema.items !== undefined) v.forEach((item, i) => check(schema.items, item, `${path}[${i}]`, errors));
  }
  if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
    const props = schema.properties || {};
    for (const name of schema.required || []) {
      if (!Object.prototype.hasOwnProperty.call(v, name)) errors.push(`${path}: missing required field ${name}`);
    }
    for (const [name, value] of Object.entries(v)) {
      if (Object.prototype.hasOwnProperty.call(props, name)) check(props[name], value, `${path}.${name}`, errors);
      else if (schema.additionalProperties === false) errors.push(`${path}: unknown field ${name}`);
    }
  }
}

export function validate(schema, value) {
  assertSupported(schema);
  const errors = [];
  check(schema, value, '$', errors);
  return { ok: errors.length === 0, errors };
}
