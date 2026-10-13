// BH-5667 (BH-5008 child 1): signed, real-shaped GitHub deliveries for one
// Mergify merge-queue batch. The siblings of BH-5008 import this file by its
// path, so the name and the exports are the contract:
//
//   REPO, SECRET          the repo slug and the webhook secret the env carries
//   DRAFT, MEMBERS        the 3-member batch draft and its member PRs
//   deliveries            [{ event, id, payload }] in arrival order:
//                         pull_request.opened #9001, 14 check_run.created,
//                         10 check_run.completed (1 failure), then
//                         pull_request.opened #9002 (2 members)
//   negatives             the adversarial deliveries of invariant (c)
//   sendDelivery(worker, env, delivery, opts)
//                         signs the raw body with HMAC-SHA256 and POSTs it to
//                         /webhooks/github through the REAL worker.fetch.
//
// Field names follow GitHub's documented webhook payloads: pull_request.head
// {ref, sha, repo.full_name}, check_run {name, head_sha, status, conclusion,
// html_url, started_at, completed_at, check_suite.head_branch,
// pull_requests[].head.ref}.
import { createHmac } from 'node:crypto';

export const REPO = 'Example-Org/example-repo';
export const SECRET = 'gh-secret-fixture';
export const DRAFT = 9001;
export const MEMBERS = [101, 102, 103];
export const BASE_SHA = '1111111111111111111111111111111111111111';
const HEAD_SHA = '2222222222222222222222222222222222222222';
const HEAD_SHA_2 = '3333333333333333333333333333333333333333';
export const MQ_REF = 'mergify/merge-queue/fixture-batch-9001';
export const MQ_REF_2 = 'mergify/merge-queue/fixture-batch-9002';

const repository = (full_name = REPO) => ({ full_name, name: full_name.split('/')[1], owner: { login: full_name.split('/')[0] } });

// Mergify's draft body names the embarked PRs as `#<n>` references.
export const mergifyBody = (members) => [
  `This pull request has been created by Mergify to speculatively check the mergeability of ${members.map((n) => `#${n}`).join(', ')}.`,
  "You don't need to do anything. Mergify will close this pull request automatically when it is complete.",
  '',
  `Branch **main** (${BASE_SHA.slice(0, 7)}) and [${members.map((n) => `#${n}`).join(', ')}] are embarked together for merge.`,
].join('\n');

// pull_request delivery. `o` overrides: action, number, ref, headRepo, repo,
// body, merged, closed_at, label.
export function prDelivery(id, o = {}) {
  const repo = o.repo || REPO;
  const number = o.number ?? DRAFT;
  const payload = {
    action: o.action || 'opened',
    number,
    pull_request: {
      number,
      html_url: `https://github.com/${repo}/pull/${number}`,
      state: o.action === 'closed' ? 'closed' : 'open',
      draft: true,
      body: o.body ?? mergifyBody(MEMBERS),
      created_at: o.created_at || '2026-10-09T03:00:00Z',
      closed_at: o.closed_at ?? null,
      merged: o.merged ?? false,
      head: { ref: o.ref || MQ_REF, sha: o.sha || HEAD_SHA, repo: repository(o.headRepo || repo) },
      base: { ref: 'main', sha: BASE_SHA, repo: repository(repo) },
    },
    repository: repository(repo),
    sender: { login: 'mergify[bot]' },
  };
  if (o.label) payload.label = { name: o.label };
  return { event: 'pull_request', id, payload };
}

// check_run delivery. `o` overrides: action, name, status, conclusion, ref,
// draft, prRef, started_at, completed_at, repo, html_url.
export function checkDelivery(id, o = {}) {
  const repo = o.repo || REPO;
  const ref = o.ref || MQ_REF;
  const draft = o.draft ?? DRAFT;
  const sha = o.sha || HEAD_SHA;
  const status = o.status || (o.action === 'completed' ? 'completed' : 'queued');
  return {
    event: 'check_run',
    id,
    payload: {
      action: o.action || 'created',
      check_run: {
        id: 50000 + Number(String(id).replace(/\D/g, '').slice(-6) || 0),
        name: o.name || 'lint',
        head_sha: sha,
        status,
        conclusion: status === 'completed' ? (o.conclusion || 'success') : null,
        html_url: o.html_url ?? `https://github.com/${repo}/actions/runs/7001/job/${8000 + draft}`,
        started_at: o.started_at || '2026-10-09T03:01:00Z',
        completed_at: status === 'completed' ? (o.completed_at || '2026-10-09T03:09:00Z') : null,
        check_suite: { id: 6001, head_branch: ref, head_sha: sha },
        pull_requests: o.noPrs ? [] : [{
          number: draft,
          head: { ref: o.prRef || ref, sha, repo: { name: repo.split('/')[1] } },
          base: { ref: 'main', sha: BASE_SHA, repo: { name: repo.split('/')[1] } },
        }],
      },
      repository: repository(repo),
      sender: { login: 'github-actions[bot]' },
    },
  };
}

export function suiteDelivery(id, o = {}) {
  const repo = o.repo || REPO;
  const ref = o.ref || MQ_REF;
  return {
    event: 'check_suite',
    id,
    payload: {
      action: o.action || 'completed',
      check_suite: {
        id: 6001, head_branch: ref, head_sha: HEAD_SHA, status: 'completed', conclusion: 'failure',
        pull_requests: [{ number: o.draft ?? DRAFT, head: { ref, sha: HEAD_SHA, repo: { name: repo.split('/')[1] } } }],
      },
      repository: repository(repo),
    },
  };
}

// The 14 jobs of the batch's CI, as GitHub names them (matrix shards carry a
// ` (n)` suffix). The first 10 complete; `Jobs worker` is the one failure.
export const CHECK_NAMES = [
  'lint', 'shellcheck', 'bash -n', 'Jobs worker', 'console-ui', 'verification-map',
  'tests (1)', 'tests (2)', 'tests (3)', 'tests (4)', 'tests (5)', 'tests (6)', 'tests (7)', 'tests (8)',
];
export const COMPLETED = CHECK_NAMES.slice(0, 10);
export const FAILED_CHECK = 'Jobs worker';

export const deliveries = [
  prDelivery('mq-0001'),
  ...CHECK_NAMES.map((name, i) => checkDelivery(`mq-c${String(i + 1).padStart(3, '0')}`, { name, action: 'created' })),
  ...COMPLETED.map((name, i) => checkDelivery(`mq-d${String(i + 1).padStart(3, '0')}`, {
    name, action: 'completed', status: 'completed', conclusion: name === FAILED_CHECK ? 'failure' : 'success',
  })),
  prDelivery('mq-0002', { number: 9002, ref: MQ_REF_2, sha: HEAD_SHA_2, body: mergifyBody([101, 102]) }),
];

// Invariant (c): each of these must write 0 rows in the three merge-queue
// tables and 0 state='queue' pr_state_events rows.
export const negatives = [
  { name: 'ref ticket/mergify/merge-queue-x', ...prDelivery('neg-1', { ref: 'ticket/mergify/merge-queue-x' }) },
  { name: 'ref mergify/merge-queue with no suffix', ...prDelivery('neg-2', { ref: 'mergify/merge-queue' }) },
  {
    name: 'check_run.completed on a member branch ticket/bh-101',
    ...checkDelivery('neg-3', { action: 'completed', status: 'completed', ref: 'ticket/bh-101', draft: 101, name: 'lint' }),
  },
  {
    name: 'pull_request.labeled queued on member #101',
    ...prDelivery('neg-4', { action: 'labeled', label: 'queued', number: 101, ref: 'ticket/bh-101', body: 'fix' }),
  },
  { name: 'MQ ref from a repo that is not in the fleet', ...prDelivery('neg-5', { repo: 'someone-else/example-repo' }) },
  { name: 'MQ ref whose head is a fork', ...prDelivery('neg-6', { headRepo: 'forker/example-repo' }) },
];

export const sign = (secret, raw) => 'sha256=' + createHmac('sha256', secret).update(raw).digest('hex');

// POST one delivery through the real worker. opts.id overrides the delivery
// id (a redelivery with a NEW id), opts.noId sends none.
export async function sendDelivery(worker, env, delivery, opts = {}) {
  const raw = JSON.stringify(delivery.payload);
  const headers = {
    'content-type': 'application/json',
    'x-github-event': delivery.event,
    'x-hub-signature-256': sign(env.GITHUB_WEBHOOK_SECRET || SECRET, raw),
  };
  const id = opts.id ?? delivery.id;
  if (!opts.noId && id) headers['x-github-delivery'] = id;
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body: raw }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
