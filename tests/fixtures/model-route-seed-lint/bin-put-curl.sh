#!/bin/bash
# A one-shot that moves live with curl rather than the jobs client.
curl -sS -X PUT -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
  --data '{"role":"build.qa","ladder":[{"model":"model-x","runner":"claude"}],"actor":"bh-0000"}' \
  "$JOBS_URL/api/model-routes"
