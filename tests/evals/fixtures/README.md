# No fixtures in this copy

Upstream, this directory holds ~20 captured triage decisions — one directory
each, with `inputs.md` (the ticket exactly as the prompt saw it), `expected.txt`
(the verdict class the fleet actually issued), `scope.txt` and `meta.json`.
`tests/evals/run-evals.sh` replays a prompt change against them and fails if the
decision policy moved.

Every one of them is a real ticket thread off a real customer's product board:
titles, comment threads, staff writing about their own business, links into
their tools. That is exactly what makes them useful as a regression baseline and
exactly why they are not published here.

To build your own baseline, point `tests/evals/capture-fixture.py` at your board
after the harness has been triaging for a while. Capture decisions you agree
with, including the SKIPs — a suite of nothing but launches will not catch a
prompt that has forgotten how to refuse.
