// SPDX-License-Identifier: Apache-2.0
// @example-org/agent-core: pure functions for the agent anatomy in SPEC.md.
// No network, no DB, no model call.
export { parseSoul, validateSoul } from './soul.js';
export { LEVELS, decide, nextLevel } from './autonomy.js';
export { fingerprint, canonicalUrl } from './fingerprint.js';
export { sha256 } from './sha256.js';
export { isOwnOutput, precision } from './learning.js';
export { validate } from './validate.js';
