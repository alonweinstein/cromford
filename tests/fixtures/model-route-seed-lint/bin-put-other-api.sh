#!/bin/bash
# A PUT, naming build.qa, to a DIFFERENT API: not the audited model-routes PUT.
. "$(dirname "$0")/jobs-client.sh"
_jobs_req PUT /api/settings '{"key":"model_note","role":"build.qa","value":"x"}'
