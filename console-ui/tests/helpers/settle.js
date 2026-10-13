import { options } from 'preact';
// preact/hooks runs useEffect after a 35 ms REAL timer when there is no
// requestAnimationFrame (node). A fixed wall-clock wait races it on a loaded
// box: both timers expire in one timers phase and the test asserts before
// the effect ran (BH-3554). Route effects through a 0 ms timer and settle by
// turns, not by milliseconds.
options.requestAnimationFrame = (cb) => setTimeout(cb, 0);
export const flush = async (ms = 0, turns = 20) => {
  if (ms > 0) await new Promise((r) => setTimeout(r, ms));
  for (let i = 0; i < turns; i++) await new Promise((r) => setTimeout(r, 0));
};
