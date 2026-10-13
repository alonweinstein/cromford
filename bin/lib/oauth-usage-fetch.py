#!/usr/bin/env python3
"""bin/lib/oauth-usage-fetch.py — the ONE network call behind bin/quota-poll.sh.

Reads the OAuth access token from the environment (OAUTH_USAGE_TOKEN) and prints
Anthropic's /api/oauth/usage response verbatim on stdout. Nothing else: the
caller normalizes, the caller writes files.

THE TOKEN COMES FROM THE ENVIRONMENT, NEVER FROM ARGV. argv is world-readable in
/proc and lands in any `ps` a human or a hook happens to run, which is exactly
the kind of leak the harness's no-secrets-in-logs rule exists to prevent. The
token is also never echoed back: on failure the urllib exception is what reaches
stderr, and the caller classifies from that text alone (same shape as
bin/extra-usage-track.sh's classifier).

Override with OAUTH_USAGE_FETCH to substitute a stub — that is how
tests/account-routing-test.sh exercises the poller without a network.
"""
import json
import os
import sys
import urllib.request

TOKEN = os.environ.get("OAUTH_USAGE_TOKEN") or ""
if not TOKEN:
    raise SystemExit("NO_TOKEN")

URL = os.environ.get("OAUTH_USAGE_URL", "https://api.anthropic.com/api/oauth/usage")
TIMEOUT = float(os.environ.get("OAUTH_USAGE_TIMEOUT", "20"))

req = urllib.request.Request(
    URL,
    headers={"Authorization": f"Bearer {TOKEN}", "anthropic-beta": "oauth-2025-04-20"},
)
body = urllib.request.urlopen(req, timeout=TIMEOUT).read()
# Parse before printing: a 200 carrying HTML (a captive portal, a proxy error
# page) must fail here rather than land in state/quota/<account>.json as "ok".
json.dump(json.loads(body), sys.stdout)
sys.stdout.write("\n")
