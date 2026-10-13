#!/bin/bash
# Calls the API for build.qa.x, a DIFFERENT role that only shares a prefix.
. "$(dirname "$0")/jobs-client.sh"
_jobs_req PUT /api/model-routes '{"role":"build.qa.x","ladder":[{"model":"model-x","runner":"claude"}]}'
