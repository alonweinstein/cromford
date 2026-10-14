#!/bin/bash
# tests/lib/linear-children-stub.sh — a stateful api.linear.app/graphql (and the
# jobs worker's settings route) for the Linear child-filing suites. Sourced
# AFTER tests/lib/scratch.sh with S (its state dir) set; writes $T/stub/curl
# and $T/stub/gh. Created issues, relations, requests and comment bodies land
# in $S: created, rels, reqs, create-<key>.json, comment-body.
# Answers: TrkParent ($S/nolabel = no build label), TrkChildCreate (an id it
# has seen is refused), TrkChildFind, TrkRelate, TrkRelFind, TrkIssueMeta,
# TrkIssue (description from $S/body), TrkComment, TrkRemoveLabel, TrkUpdate,
# TrkAttach, TrkGate ($S/blocker = the blocker's state type), TrkParentOf
# ($S/parentof). Needs TL_STATE, TL_KEY_EXPECT, TL_FIX, PARENT_ID, TEAM_ID,
# PARENT_LABEL in the environment.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TL_STATE"; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|-m|--max-time|--connect-timeout) shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi; printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"; exit 0; }
case "$url" in
  https://jobs.example/api/settings/*)
    f="$S/setting-${url##*/}"; [ -r "$f" ] && reply 200 "$(cat "$f")"
    reply 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) reply 404 '{}' ;;
  https://api.linear.app/graphql) ;;
  *) echo "OFFBASE $url" >> "$S/reqs"; printf '000'; exit 7 ;;
esac
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
V() { jq -r "$1" "$data"; }
[ "$auth" = "$TL_KEY_EXPECT" ] || reply 401 '{"errors":[{"message":"Authentication required"}]}'
no() { reply 400 "{\"errors\":[{\"message\":\"$1\"}]}"; }
case "$op" in
  TrkParent)
    echo "TrkParent $(V .variables.id)" >> "$S/reqs"
    lab='[{"id":"'"$PARENT_LABEL"'","name":"ai-build","team":null}]'; [ -e "$S/nolabel" ] && lab='[]'
    reply 200 "{\"data\":{\"issue\":{\"id\":\"$PARENT_ID\",\"priority\":2,\"team\":{\"id\":\"$TEAM_ID\",\"key\":\"CRO\"}},\"issueLabels\":{\"nodes\":$lab}}}" ;;
  TrkChildCreate)
    id=$(V .variables.in.id)
    grep -q "^$id " "$S/created" 2>/dev/null && { echo "TrkChildCreate-dup $id" >> "$S/reqs"; no "id already exists"; }
    n=$(( $(cat "$S/next" 2>/dev/null || echo 20) )); echo $((n + 1)) > "$S/next"
    echo "$id CRO-$n" >> "$S/created"
    jq -c '.variables.in' "$data" > "$S/create-CRO-$n.json"
    echo "TrkChildCreate CRO-$n" >> "$S/reqs"
    reply 200 "{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":{\"identifier\":\"CRO-$n\"}}}}" ;;
  TrkChildFind)
    id=$(V .variables.id); echo "TrkChildFind $id" >> "$S/reqs"
    k=$(awk -v i="$id" '$1 == i {print $2}' "$S/created" 2>/dev/null)
    [ -n "$k" ] || no "Entity not found"
    reply 200 "{\"data\":{\"issue\":{\"identifier\":\"$k\",\"parent\":{\"id\":\"$PARENT_ID\"}}}}" ;;
  TrkRelate)
    id=$(V .variables.in.id)
    grep -q "^$id " "$S/rels" 2>/dev/null && no "duplicate relation"
    a=$(awk -v i="$(V .variables.in.issueId)" '$1 == i {print $2}' "$S/created")
    b=$(awk -v i="$(V .variables.in.relatedIssueId)" '$1 == i {print $2}' "$S/created")
    echo "$id $a blocks $b" >> "$S/rels"; echo "TrkRelate $a $b" >> "$S/reqs"
    reply 200 '{"data":{"issueRelationCreate":{"success":true}}}' ;;
  TrkRelFind)
    grep -q "^$(V .variables.id) " "$S/rels" 2>/dev/null || no "Entity not found"
    reply 200 '{"data":{"issueRelation":{"id":"r"}}}' ;;
  TrkIssueMeta) reply 200 "$(cat "$TL_FIX/issue-CRO-1.json")" ;;
  TrkIssue) echo "TrkIssue $(V .variables.id)" >> "$S/reqs"
    reply 200 "$(jq -c --rawfile d "$S/body" '.data.issue.description = $d' "$TL_FIX/issue-CRO-1.json")" ;;
  TrkComment) echo "TrkComment $(V .variables.id)" >> "$S/reqs"; V .variables.body >> "$S/comment-body"
    reply 200 '{"data":{"commentCreate":{"success":true,"comment":{"id":"c-1"}}}}' ;;
  TrkRemoveLabel) echo "TrkRemoveLabel $(V .variables.labelId)" >> "$S/reqs"
    reply 200 '{"data":{"issueRemoveLabel":{"success":true}}}' ;;
  TrkUpdate) echo "TrkUpdate $(V .variables.id) $(V .variables.stateId)" >> "$S/reqs"
    reply 200 "$(jq -c '{data:{issueUpdate:{success:true,issue:{state:{id:.variables.stateId}}}}}' "$data")" ;;
  TrkAttach) reply 200 '{"data":{"attachmentLinkURL":{"success":true,"attachment":{"id":"a-1"}}}}' ;;
  TrkGate)
    rel='[]'; [ -r "$S/blocker" ] && rel="[{\"type\":\"blocks\",\"issue\":{\"identifier\":\"CRO-20\",\"state\":{\"type\":\"$(cat "$S/blocker")\"}}},{\"type\":\"related\",\"issue\":{\"identifier\":\"CRO-9\",\"state\":{\"type\":\"started\"}}}]"
    reply 200 "{\"data\":{\"viewer\":{\"id\":\"u-me\"},\"issue\":{\"identifier\":\"$(V .variables.id)\",\"team\":{\"key\":\"CRO\"},\"inverseRelations\":{\"nodes\":$rel},\"comments\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}" ;;
  TrkParentOf) echo "TrkParentOf $(V .variables.id)" >> "$S/reqs"; reply 200 "$(cat "$S/parentof")" ;;
esac
no "the stub has no such operation $op"
SH
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$TL_STATE/gh.log"\nexit 1\n' > "$T/stub/gh"
chmod +x "$T/stub/curl" "$T/stub/gh"
