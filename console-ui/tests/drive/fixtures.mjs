// Fixture payloads for the headless drive of /world.
//
// This box cannot reach the live console's authed reads, so the drive serves
// the SAME four endpoint shapes the screen reads in production and nothing
// else — /api/coord/jobs, /api/cockpit/needs, /api/dash/machines,
// /api/dash/projects. Every project name here is a name already in fleet.conf.
// If the fixture shape and the worker's shape ever part company, the drive is
// proving something about a fixture rather than about the console, so the
// fields below are kept to the ones lib/world.js and lib/jobs.js actually read.

// determinism: ok-file clock-now-js clock-new-date fixtures are offsets from one captured now (and a
// generated_at the screen only renders), so the drive proves shapes, never a date.
const now = Math.floor(Date.now() / 1000);

export const jobs = {
  jobs: [
    { id: 'build-project-3-TK-104-1', project: 'project-3', kind: 'build', ticket_id: 'TK-104', box: 'project-3-2', stage: 'execute', status: 'running', heartbeating: 1, activity_age_s: 40, started_at: now - 900 },
    { id: 'build-project-3-TK-107-1', project: 'project-3', kind: 'build', ticket_id: 'TK-107', box: 'project-3-2', stage: 'review', status: 'running', heartbeating: 1, activity_age_s: 95, started_at: now - 400 },
    { id: 'triage-project-1-1', project: 'project-1', kind: 'triage', box: 'project-1-1', stage: 'triage', status: 'running', heartbeating: 1, activity_age_s: 20, started_at: now - 120 },
    { id: 'build-project-1-TK-58-1', project: 'project-1', kind: 'build', ticket_id: 'TK-58', box: 'project-1-1', stage: 'plan', status: 'parked', heartbeating: 0, activity_age_s: 3600, started_at: now - 7200 },
    { id: 'build-project-2-TK-201-1', project: 'project-2', kind: 'build', ticket_id: 'TK-201', box: 'project-2-1', stage: 'execute', status: 'running', heartbeating: 1, activity_age_s: 1900, started_at: now - 5400 },
    { id: 'build-project-4-AC-12-1', project: 'project-4', kind: 'build', ticket_id: 'AC-12', box: 'project-4-1', stage: 'qa', status: 'queued_for_retry', heartbeating: 0, activity_age_s: 300, started_at: now - 1800 },
    { id: 'build-project-5-TK-9-1', project: 'project-5', kind: 'build', ticket_id: 'TK-9', box: 'project-5-1', stage: 'execute', status: 'running', heartbeating: 1, activity_age_s: 65, started_at: now - 300 },
    { id: 'build-project-9-TK-3-1', project: 'project-9', kind: 'build', ticket_id: 'TK-3', box: 'project-9-1', stage: 'security', status: 'budget_stopped', heartbeating: 0, activity_age_s: 2400, started_at: now - 9000 },
    { id: 'build-cromford-BH-7-1', project: 'cromford', kind: 'build', ticket_id: 'BH-7', box: 'hub-1', stage: 'execute', status: 'running', heartbeating: 1, activity_age_s: 55, started_at: now - 700 },
    { id: 'build-project-3-TK-99-1', project: 'project-3', kind: 'build', ticket_id: 'TK-99', box: 'project-3-1', stage: 'plan', status: 'done', heartbeating: 0, activity_age_s: 30, started_at: now - 8000 }
  ]
};

export const projects = {
  projects: [
    { project: 'project-3', open_prs: 3, open_alerts: 0, last_run_age_min: 4, fleet: { queue_depth: 5 } },
    { project: 'project-1', open_prs: 1, open_alerts: 2, last_run_age_min: 9, fleet: { queue_depth: 2 } },
    { project: 'project-2', open_prs: 2, open_alerts: 0, last_run_age_min: 12, fleet: { queue_depth: 1 } },
    { project: 'project-4', open_prs: 0, open_alerts: 1, last_run_age_min: 22, fleet: { queue_depth: 0 } },
    { project: 'project-5', open_prs: 1, open_alerts: 0, last_run_age_min: 6, fleet: { queue_depth: 0 } },
    { project: 'project-9', open_prs: 0, open_alerts: 0, last_run_age_min: 41, fleet: { queue_depth: 0 } },
    { project: 'cromford', open_prs: 4, open_alerts: 0, last_run_age_min: 2, fleet: { queue_depth: 3 } },
    { project: 'project-6', open_prs: 0, open_alerts: 0, paused: 1, last_run_age_min: 300, fleet: { queue_depth: 0 } },
    { project: 'project-8', open_prs: 0, open_alerts: 0, last_run_age_min: 55, fleet: { queue_depth: 0 } }
  ]
};

export const machines = {
  boxes: {
    'project-3-1': '2m ago', 'project-3-2': '1m ago', 'project-1-1': '3m ago',
    'project-2-1': '2m ago', 'project-4-1': '4m ago', 'project-5-1': '1m ago',
    'project-9-1': '6h ago', 'hub-1': '1m ago', 'small-1': '5m ago'
  }
};

export const needs = {
  alerts: [
    { id: 11, project: 'project-1', akey: 'board-api-401', line: 'board API answered 401 twice in a row', ts: now - 1200 },
    { id: 12, project: null, akey: 'hub-disk', line: 'hub disk at 91%', ts: now - 400 }
  ],
  commands: [
    { id: 44, project: 'project-4', type: 'build', status: 'dead_letter', result: 'typecheck failed 3x', ckey: 'project-4-AC-12', updated_at: now - 3000 }
  ],
  builds: [
    { id: 91, project: 'project-9', bkey: 'TK-3', ticket_key: 'TK-3', stage: 'security', tier: 2, verdict: 'needs a human', updated_at: now - 5000 },
    { id: 92, project: 'project-3', bkey: 'TK-104', ticket_key: 'TK-104', stage: 'pr_created', tier: 1, verdict: 'awaiting merge', pr_url: 'https://example.invalid/pr/1', updated_at: now - 900 }
  ],
  proposals: []
};

export const fleet = {
  generated_at: new Date().toISOString(),
  boxes: [],
  projects: projects.projects,
  open_alerts: 3
};

export const ROUTES = {
  '/api/dash/fleet': fleet,
  '/api/dash/machines': machines,
  '/api/dash/projects': projects,
  '/api/coord/jobs': jobs,
  '/api/cockpit/needs': needs
};
