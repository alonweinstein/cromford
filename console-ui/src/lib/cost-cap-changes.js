// BH-2567: the cap change log's body, read without preact so the shell suite
// can drive it on a box with no console-ui dependencies installed.

// A body without a `changes` array is an error, never "no changes".
export function changeRows(res) {
  if (!res || typeof res !== 'object' || !Array.isArray(res.changes)) {
    return { rows: [], truncated: false, malformed: true };
  }
  return { rows: res.changes, truncated: res.truncated === true, malformed: false };
}
