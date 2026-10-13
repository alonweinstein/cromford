// Guarded tools: each sends one POST /api/dash/action {type, ...args}, and
// only when confirm is the boolean true AND the repo is on
// HARNESS_MCP_REPO_ALLOWLIST. The allowlist is empty by default, so out of
// the box these tools refuse every call and send nothing.
import { forward } from '../lib/tools.mjs';
import { checkArgs } from './lib/schema.mjs';

const obj = (properties, required) => ({ type: 'object', properties, required, additionalProperties: false });
const REPO = { type: 'string', minLength: 1, maxLength: 200 };
const PR = { type: 'integer', minimum: 1 };
const BOOL = { type: 'boolean' };

// One guard for both tools. The match is exact on the trimmed, lowercased
// repo, the same normalization loadConfig applies to the allowlist.
function guard(args, ctx) {
  if (args.confirm !== true) return 'confirm_required';
  const repo = typeof args.repo === 'string' ? args.repo.trim().toLowerCase() : '';
  if (!ctx.cfg.allowlist.includes(repo)) return 'repo_not_allowlisted';
  return null;
}

const guarded = (name, description, inputSchema) => {
  const check = checkArgs(inputSchema);
  return {
    name, description, kind: 'guarded', inputSchema,
    precheck: (args, ctx) => guard(args, ctx) ?? check(args),
    handler: (args, ctx) => forward(ctx, 'POST', '/api/dash/action', { type: name, ...args }),
  };
};

export const tools = [
  guarded('merge_pr', 'Merge a pull request on an allowlisted repo. Needs confirm: true.',
    obj({ repo: REPO, pr: PR, confirm: BOOL }, ['repo', 'pr', 'confirm'])),
  guarded('set_automerge', 'Turn auto-merge on or off for a pull request on an allowlisted repo. Needs confirm: true.',
    obj({ repo: REPO, pr: PR, enabled: BOOL, confirm: BOOL }, ['repo', 'pr', 'enabled', 'confirm'])),
];
