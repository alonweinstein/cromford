// console-ui/src/lib/deployment.js — BH-4080: the console's deployment
// defaults, in one place. The console is a static Pages build with no box env,
// and its settings proxy only serves settable rows, so these two values are
// constants here rather than knobs; making them console-editable is #3979 wave 8
// (console-driven configuration). The shell side's equivalents live in
// bin/lib/deployment.sh (HARNESS_OPERATOR_LOGIN, HARNESS_WORKERS_SUBDOMAIN), and
// bin/deployment-lint.sh keeps these literals out of every other file.

// The GitHub login every one of OUR lanes authenticates as (one shared PAT).
export const FLEET_LOGIN = 'operator';

// The old console's product cockpit, where the approve / kill / revise gate lives.
export const PRODUCT_COCKPIT_URL = 'https://harness-console.operator.workers.dev/product';
