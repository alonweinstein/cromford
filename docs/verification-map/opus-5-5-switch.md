# Opus 5.5 switch (the Opus rung, the reviewer, and the CLI floor)

**What it is:** every place the harness chose Opus by default, and every review
default, now names `claude-opus-5-5` (BH-1507). The claude failover in
`bin/agent-call.sh`: fable → `claude-opus-5-5`; an Opus lane's list that ends
on 5.5 carries `claude-opus-5` behind it as the CLI FLOOR, reached ONLY when the
CLI refuses the model: under `--output-format json` Claude Code older than
2.1.280 answers an `is_error` envelope reading "does not support this model;
version 2.1.280 or newer is required" (text mode: "isn't described by this
version's model catalog"). One `CLI FLOOR` line in ALERTS names the CLI
version, once per box per model per day (`flags/alerted-cli-floor-*`). The review lane's tail is `claude-fable-5-1` instead, reached on any
failure (kill, timeout and context stops excepted, as before). An ordinary 5.5
failure on an Opus lane never buys a run on Opus 5.

**How an operator reaches it:** every build and every claude lane, with no
flag. The model a lane uses is still set the way it was (`env/global.env`, the
existing catalog knobs); moving every model id into the DB is #1510.

**Key files/blocks:**
- `bin/agent-call.sh` — since #1510.1 the rungs are `model_routes` rows, not
  the `OPUS_RUNG` / `OPUS_FLOOR` / `REVIEW_TAIL` literals: `claude_ladder`, and
  the `THE CLI FLOOR` block in the candidate loop (see
  [../MODEL-ROUTES.md](../MODEL-ROUTES.md)).
- `bin/lib/review-model.sh` (the `build.review` route since #1510.1);
  `bin/review-prs.sh` asks `review_model` instead of passing a literal.
- `catalog/model-prices.json`, `catalog/model-slugs.json`,
  `bin/update-model-prices.sh` MAP; `catalog/cli-min-versions.json` (the
  2.1.280 floor).

**Preconditions:** Claude Code >= 2.1.280 on every box and in every Fly builder
image, or 5.5 calls there degrade (Opus lanes to Opus 5, reviews to Fable 5.1)
with the ALERTS line until `bin/cli-update.sh` / `bin/fly-image-refresh.sh`
catch up.

**How you drive it:**

| what | how |
|---|---|
| prices, every default, both failover ladders, the CLI-floor error | `HARNESS_TEST_SANDBOX=1 bash tests/opus-5-5-switch.bh-1507-test.sh` |
| account rotation with the 5.5 rung | `HARNESS_TEST_SANDBOX=1 bash tests/account-routing-test.sh` |
