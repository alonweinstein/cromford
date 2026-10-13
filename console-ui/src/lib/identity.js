// The top bar's identity pill (BH-2515): who this session's writes are
// recorded as, from GET /api/coord/whoami ({actor, access, email}). Every
// state says what a write will carry; a failed or unrecognised read says it is
// unknown, never "off", because nobody checked.

const CONSOLE_NOTE = 'so every change you make here is recorded as console';
// harness-console's pauseCommand() rebuilds the command payload without the
// actor, so pause_board / pause_set rows record console. The 'on' title names
// that exception rather than claiming every change.
const COMMAND_NOTE = 'Pause and resume commands are the exception: they are recorded as console';

export function identityPill(whoami, error) {
  if (error) {
    return { text: 'identity unknown', tone: 'warn', title: `Could not read who this session writes as (${error.message || error})` };
  }
  if (!whoami) return { text: 'identity…', tone: 'muted', title: 'Checking who this session writes as' };
  switch (whoami.access) {
    case 'on':
      return { text: whoami.email, tone: 'ok', title: `Settings, routing, job, alert and hub writes you make here are recorded as ${whoami.email}. ${COMMAND_NOTE}` };
    case 'off':
      return { text: 'ACCESS OFF · writes as console', tone: 'warn',
        title: 'Cloudflare Access is not configured on this console, ' + CONSOLE_NOTE };
    case 'unverified':
      return { text: 'IDENTITY UNVERIFIED · writes as console', tone: 'warn',
        title: 'Cloudflare Access is configured, but this request carried no verifiable Access login, ' + CONSOLE_NOTE };
    case 'unrecordable':
      return { text: `${whoami.email} · recorded as console`, tone: 'warn',
        title: `${whoami.email} has a character the audit log cannot store, ` + CONSOLE_NOTE };
    default:
      return { text: 'identity unknown', tone: 'warn', title: `Unrecognised identity state: ${String(whoami.access)}` };
  }
}
