#!/bin/bash
# A one-shot that moves live: PUT the new build.qa ladder through the audited API.
. "$(dirname "$0")/jobs-client.sh"
_jobs_req PUT /api/model-routes '{"role":"build.qa","ladder":[{"model":"model-x","runner":"claude"}],"actor":"bh-0000"}'
