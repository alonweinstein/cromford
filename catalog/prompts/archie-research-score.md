# Archie research: does this apply to us? (BH-4065, BH-4762)

Below is a JSON array of finds from the web and from X. Each has a key, a
source, a url, a title and some text. Our factory is this harness: Claude Code
sessions on always-on boxes that watch product boards, triage tickets, plan,
build, review and merge PRs through gated lanes, with a jobs DB, cost ledger,
model routes and an Ideas screen for proposals.

For EACH find, decide whether it applies to us: would adopting it make the
factory measurably better (less rework, less spend, faster merges, fewer
stalls, better reviews)? Score it 0 to 10. 7 or more means you would put it in
front of the operator as a proposal.

Be strict. Something we already do, something vague, or something with no
evidence behind it scores low. Push back on hype. A find whose text says the
transcript was not read was judged from its title and description only: score
it on what that shows, not on what the video might say.

When a find applies, say what it changes in OUR pipeline:

- `stage`: exactly one of `triage`, `plan`, `execute`, `review`, `merge`,
  `cost`, `model-routing`. Required when applies is true.
- `change`: the concrete change to our pipeline, in one or two sentences.
- `effect`: the effect we expect, with a number where one is honest, for
  example "about 20% fewer review fix rounds".
- `cost`: what it costs us to try: sessions, dollars per day.
- `model_route`: only for a new model release that is better or cheaper for a
  stage we run. Name the `model_routes` role to change, for example
  `stage.review`. You suggest it. Nobody changes routing because of this
  answer, and you never change routing yourself.

## Answer

Return ONLY a JSON array, one entry per find, using the find's key exactly:

[{"key": "<the find's key>", "applies": true or false, "score": <0-10>, "why": "<one or two plain sentences on why it does or does not apply to us>", "proposal_title": "<a short imperative title for the idea>", "proposal_summary": "<two or three sentences: what we would change and what we expect it to improve>", "stage": "<one of the stages above>", "change": "<the change>", "effect": "<the expected effect>", "cost": "<what it costs to try>", "model_route": "<a model_routes role, only for a model release>"}]

Use only the finds below; never add one. Plain English, first person plural,
no em dashes or en dashes, no markdown inside the strings.
