#!/bin/bash
# prod-url.sh <project> — echo the client-facing production base URL.
# Single source of truth is fleet.conf (via fleet-conf.sh); the builtin map
# below is a fallback for boxes that haven't synced fleet.conf yet.
P="${1:?project}"
URL=$("$(dirname "$0")/fleet-conf.sh" "$P" prod 2>/dev/null)
[ -n "$URL" ] && { echo "$URL"; exit 0; }
case "$P" in
  project-1)   echo "https://os.project-1.example" ;;
  project-2) echo "https://os.project-2.example" ;;
  project-3)       echo "https://os.project-3.example" ;;
  project-4)       echo "https://os.project-4.example" ;;
  *) exit 1 ;;
esac
