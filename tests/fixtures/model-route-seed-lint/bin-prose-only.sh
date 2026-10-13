#!/bin/bash
# The shape of bin/lib/model-route.sh: it READS the API and names the role,
# and its alert text says "PUT /api/model-routes", but it makes no PUT call.
ROLES="build.plan build.qa"
resp=$(JOBS_ALERT=0 _jobs_req GET "/api/model-routes/build.qa")
echo "no model route for build.qa — seed model_routes or PUT /api/model-routes."
