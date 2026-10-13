## 4. One alert per repo, and only when something happened

A repo where every PR has an owner produces **no alert**. That is the normal,
silent shape, and a sweep that pages on every quiet tick is a sweep nobody
reads.

When a run does act, it emits exactly ONE `bin/lane-alert.sh` line for the whole
repo, listing every PR it closed, every PR it newly labelled, and every key it
handed back — never one alert per PR. Already-labelled stale PRs are not in the
list, because nothing happened to them.

