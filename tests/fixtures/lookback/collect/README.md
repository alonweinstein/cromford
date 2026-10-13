# tests/fixtures/lookback/collect — BH-1795.1 collector fixtures

Read by `tests/lookback-collect.bh-1795-test.sh`. Every file has the shape its
real writer produces; date-bearing files are templates the suite fills from its
one `NOW` read (`@AT_IN@`/`@AT_OLD@` ISO, `@STAMP_IN@`/`@STAMP_OLD@` the
`STAMP()` format, `@DAY_IN@`/`@DAY_OLD@` the `%Y%m%d` of reopens.csv).

| file | real writer |
|---|---|
| reopens.csv | bin/reopen-metrics.sh (header `date,project,key,from,to`) |
| br-*.json | bin/blocked-resolver.sh br_save (br_load's fresh shape + attempts) |
| ledger.json | worker/jobs/src/routes/ledger.js GET /api/ledger list |
| alerts.json | worker/jobs/src/routes/alerts.js GET /api/alerts (schema.sql columns) |
| ALERTS.log | bin/postmerge-qa.sh FAILED / NOT RUN / BLOCKED lines |
| commits.json | GitHub REST GET /repos/{slug}/commits |
| pr-42-files.json, pr-43-files.json | GitHub REST GET /repos/{slug}/pulls/{n}/files |
| worker-503.json | the worker's JSON error body on a 503 |
