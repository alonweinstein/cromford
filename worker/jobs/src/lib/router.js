// harness-jobs — the router the route table is read by (BH-1195).
//
// The table is `[method, matcher, handler]` rows in chain order and matching is
// FIRST MATCH WINS, because that is exactly what the flat `if` chain this
// replaced did: `GET /api/jobs/:id` sat above `GET /api/jobs`, and a table that
// resolved by specificity (or by a map keyed on path) would quietly re-order
// routes whose order is load-bearing.
//
// EVERY MATCHER IS DATA, never a closure: a string, a list of strings, a
// `{ prefix }`, a `RegExp`, or a `{ re, not }` — so test/route-table.test.js can
// read the whole table back and compare it, route for route, with the chain it
// came from. A closure would match just as well and prove nothing.

// Returns the match (`true`, or the RegExp match array a handler reads groups
// from) or null. Never returns `false`: a handler's `m` is the match array.
export function matchPath(matcher, path) {
  if (typeof matcher === "string") return path === matcher ? true : null;
  if (Array.isArray(matcher)) return matcher.includes(path) ? true : null;
  if (matcher instanceof RegExp) return path.match(matcher);
  if (matcher && typeof matcher.prefix === "string") return path.startsWith(matcher.prefix) ? true : null;
  if (matcher && matcher.re instanceof RegExp) {
    // The chain's own guard: a path that matches the regexp but fails the guard
    // FELL THROUGH to the routes below it. Returning null here keeps that.
    const m = path.match(matcher.re);
    return m && m[1] !== matcher.not ? m : null;
  }
  throw new TypeError("route matcher is not data: " + String(matcher));
}

// `"*"` is a method wildcard, and only the GitHub webhook uses it — it answers
// its own 405 so that a GET arrives at the same route and gets the same
// sentence, instead of falling through to the bearer check.
export function matchRoute(routes, method, path) {
  for (const entry of routes) {
    const [m, matcher] = entry;
    if (m !== "*" && m !== method) continue;
    const hit = matchPath(matcher, path);
    if (hit) return { entry, handler: entry[2], m: hit === true ? null : hit };
  }
  return null;
}

// The one-line shape of a matcher, for the completeness test and for any
// readout that has to name a route without running it.
export function matcherSignature(matcher) {
  if (typeof matcher === "string") return matcher;
  if (Array.isArray(matcher)) return "any:" + matcher.join("|");
  if (matcher instanceof RegExp) return "re:" + String(matcher);
  if (matcher && typeof matcher.prefix === "string") return "prefix:" + matcher.prefix;
  if (matcher && matcher.re instanceof RegExp) return "re:" + String(matcher.re) + " !" + matcher.not;
  throw new TypeError("route matcher is not data: " + String(matcher));
}
