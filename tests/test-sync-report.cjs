const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { collect, redact } = require('../Scripts/Collect-Sync-Report.cjs');
const publish = require('../Scripts/Report-Sync-Result.cjs');

function fixture() {
  const issues = [], comments = [], updates = [];
  const github = {
    paginate: async () => issues.filter(issue => issue.state === 'open'),
    rest: {
      actions: { listJobsForWorkflowRun: async () => ({ data: { jobs: [{ name: 'sync', steps: [
        { name: 'Checkout custom', conclusion: 'failure' },
      ] }] } }) },
      issues: {
        listForRepo: () => {},
        create: async args => {
          const issue = { ...args, number: issues.length + 1, state: 'open', html_url: 'https://example.invalid/issue' };
          issues.push(issue); return { data: issue };
        },
        createComment: async args => { comments.push(args); },
        update: async args => { updates.push(args); Object.assign(issues.find(i => i.number === args.issue_number), args); },
      },
    },
  };
  return { args: { github, context: { repo: { owner: 'yyg20101', repo: 'OpenWRT-CI' }, runId: 123, sha: 'abc' },
    core: { info() {}, notice() {} } }, issues, comments, updates };
}

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sync-report-test-'));
  fs.writeFileSync(path.join(dir, 'state.tsv'), 'stage\tfetch\nstage\tmerge\nattempt\t1\n');
  fs.writeFileSync(path.join(dir, 'conflicts.txt'), 'shared.txt\n');
  fs.writeFileSync(path.join(dir, 'sync.log'), 'https://user:secret@example.invalid\nAuthorization: bearer sensitive\ngithub_pat_example\n');
  const report = collect(dir, { GITHUB_SERVER_URL: 'https://github.com', GITHUB_REPOSITORY: 'yyg20101/OpenWRT-CI', GITHUB_RUN_ID: '123' });
  assert.equal(report.stage, 'merge');
  assert.equal(report.conflicts, 'shared.txt');
  assert(!report.log_tail.includes('secret'));
  assert(!report.log_tail.includes('sensitive'));
  assert(!redact('ghp_exampleToken').includes('exampleToken'));
  const encoded = Buffer.from(JSON.stringify(report)).toString('base64');

  const f = fixture();
  await publish(f.args, { SYNC_RESULT: 'failure', SYNC_REPORT: encoded });
  assert.equal(f.issues.length, 1);
  assert(f.issues[0].body.includes('shared.txt'));
  assert(f.issues[0].body.includes('Checkout custom'));
  assert(f.issues[0].body.includes('@yyg20101'));
  assert(!f.issues[0].body.includes('sensitive'));
  await publish(f.args, { SYNC_RESULT: 'failure', SYNC_REPORT: encoded });
  assert.equal(f.issues.length, 1);
  assert.equal(f.comments.length, 1);
  await publish(f.args, { SYNC_RESULT: 'success', SYNC_REPORT: encoded });
  assert.equal(f.issues[0].state, 'closed');
  assert(f.comments[1].body.includes('已恢复'));

  const normal = fixture();
  await publish(normal.args, { SYNC_RESULT: 'success' });
  assert.equal(normal.issues.length, 0);
  const early = fixture();
  await publish(early.args, { SYNC_RESULT: 'failure' });
  assert(early.issues[0].body.includes('Checkout custom'));
  assert(early.issues[0].body.includes('脚本未执行'));
  const test = fixture();
  await publish(test.args, { SYNC_RESULT: 'failure', DIAGNOSTIC_FAILURE: 'true', SYNC_REPORT: encoded });
  assert.equal(test.issues[0].state, 'closed');
  assert(test.issues[0].body.includes('未执行分支同步'));
  assert(!test.issues[0].body.includes('@yyg20101'));
  const retry = fixture();
  await publish(retry.args, { SYNC_RESULT: 'success', SYNC_REPORT: Buffer.from(JSON.stringify({ attempt: '2' })).toString('base64') });
  assert.equal(retry.issues.length, 1);
  assert.equal(retry.issues[0].state, 'closed');
  assert(retry.issues[0].body.includes('重试后已恢复'));
  const wrong = fixture();
  wrong.args.context.repo.owner = 'VIKINGYFY';
  await assert.rejects(publish(wrong.args, { SYNC_RESULT: 'failure' }), /Unexpected repository/);
  assert.equal(wrong.issues.length, 0);
  console.log('All diagnostic collection, redaction, incident, recovery and fallback tests passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
