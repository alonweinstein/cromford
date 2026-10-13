// BH-4940: wait on the condition a test asserts, not on a fixed sleep. The
// ceiling counts polls, not wall time: a test that pins Date.now would never
// reach a Date.now() deadline, and on a stalled box a poll count only makes
// the ceiling longer, which is the safe direction.
export const WAIT_POLL_MS = 10;
export const WAIT_MAX_POLLS = 500;
export async function waitFor(ready, what, describe = () => '', maxPolls = WAIT_MAX_POLLS) {
  for (let i = 0; i < maxPolls; i++) {
    if (ready()) return;
    await new Promise((r) => setTimeout(r, WAIT_POLL_MS));
  }
  if (ready()) return;
  throw new Error(`waitFor: ${what} never appeared within ${maxPolls} polls of ${WAIT_POLL_MS} ms. ${describe()}`);
}
