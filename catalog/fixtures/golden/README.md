# Golden triage scenarios

Recorded board / queue / results states for `bin/prompt-eval.sh`. Each directory
is one tick: the inputs a triage session would have seen, and the DECISION the
SOP is supposed to reach.

**The people and the content are invented; the infrastructure is real.** Client
names ("Acme project-2"), staff names, ticket ids, ticket bodies, comment threads and
PR numbers are fictional and deliberately match no real board — a fixture
carrying a real client's thread would put that thread in every future prompt.
What is NOT fictional: repo slugs (`example-org/project-2`), production
domains (`os.project-2.example`), harness paths (`/root/harness/builds/...`) and the
board API shapes, because the SOP names them and a fixture that hid them would
not exercise the SOP. That is also why an eval session runs with no tools and a
scrubbed environment: these fixtures point at real places.

## Layout

| file | required | what it is |
|---|---|---|
| `meta.json` | yes | `gate`, `project` (**the only project this is graded against**), `board_shape` (`board-api` \| `gh-issues` \| `any`), `note` |
| `inputs.md` | yes | the board state, ticket threads, queue and build dirs as the tick would have seen them |
| `expected.txt` | yes | one line per ticket key: `KEY :: action[\|action]` |
| `scope.txt` | for scoped gates | the TICK SCOPE list (gate-diff lines / READY-QUEUE lines / unswept result dirs) |
| `scope-2.txt` | optional | queue-pending only: the `state/build-queue/<project>/` entries |

`gate` drives which TICK SCOPE preamble `prompt-eval.sh` composes, matching
`bin/run-triage.sh` (apart from one documented tail divergence — see
`docs/PROMPT-EVALS.md`). `project` decides which project the scenario is graded
against, and only that one: the board text names a real slug, domain and key
prefix, so another project's SOP would spend the tick correctly noticing the
board is not its own. `board_shape` is then a consistency assertion — a scenario
whose shape disagrees with its project's is a broken fixture and is refused.

## Allowed actions

`launch | queue | comment | status | skip | defer | close | escalate` — the
vocabulary of the DECISION-log contract in `run-triage.sh`. A pipe-separated set
means two answers are both correct; use it where the SOP genuinely permits
either, and nowhere else. A set that admits everything grades nothing.

See `docs/PROMPT-EVALS.md` for how to add a scenario and how re-baselining works.
