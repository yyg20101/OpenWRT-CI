const fs = require('node:fs');
const path = require('node:path');

function redact(text) {
  return String(text)
    .replace(/https?:\/\/[^\s/@]+:[^\s/@]+@/g, 'https://[REDACTED]@')
    .replace(/\b(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+/g, '[REDACTED]')
    .replace(/(authorization\s*[:=]\s*).*/gi, '$1[REDACTED]');
}

function collect(dir, env = process.env) {
  const read = name => fs.existsSync(path.join(dir, name)) ? fs.readFileSync(path.join(dir, name), 'utf8') : '';
  const state = {};
  for (const line of read('state.tsv').split('\n')) {
    const tab = line.indexOf('\t');
    if (tab >= 0) state[line.slice(0, tab)] = line.slice(tab + 1);
  }
  return {
    ...state,
    run_url: `${env.GITHUB_SERVER_URL}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}`,
    run_attempt: env.GITHUB_RUN_ATTEMPT,
    event: env.GITHUB_EVENT_NAME,
    workflow_sha: env.GITHUB_SHA,
    conflicts: redact(read('conflicts.txt')).trim(),
    log_tail: redact(read('sync.log')).slice(-16000),
  };
}

if (require.main === module) {
  const dir = process.env.SYNC_LOG_DIR;
  const report = collect(dir);
  const json = JSON.stringify(report);
  fs.writeFileSync(path.join(dir, 'report.json'), `${json}\n`);
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `report=${Buffer.from(json).toString('base64')}\n`);
  }
}

module.exports = { collect, redact };
