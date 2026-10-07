const { redact } = require('./Collect-Sync-Report.cjs');

module.exports = async ({ github, context, core }, env = process.env) => {
  if (context.repo.owner !== 'yyg20101' || context.repo.repo !== 'OpenWRT-CI') {
    throw new Error('Unexpected repository for sync reporting');
  }
  const test = env.DIAGNOSTIC_FAILURE === 'true';
  const marker = test ? '<!-- fork-sync-report-test:v1 -->' : '<!-- fork-sync-incident:v1 -->';
  const title = test ? '[Sync Upstream] 异常上报验证' : '[Sync Upstream] 自动同步异常';
  const runUrl = `${context.serverUrl || 'https://github.com'}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  let report = {};
  if (env.SYNC_REPORT) report = JSON.parse(Buffer.from(env.SYNC_REPORT, 'base64').toString('utf8'));
  let jobs = [];
  try {
    const response = await github.rest.actions.listJobsForWorkflowRun({
      ...context.repo, run_id: context.runId, filter: 'latest', per_page: 100,
    });
    jobs = response.data.jobs;
  } catch (error) {
    core.warning(`无法读取步骤列表（HTTP ${error.status || 'unknown'}）；仍尝试保存已有诊断。`);
  }
  const failed = jobs.flatMap(job => (job.steps || [])
    .filter(step => ['failure', 'cancelled'].includes(step.conclusion))
    .map(step => `${job.name} / ${step.name}: ${step.conclusion}`));
  // checkout/凭据检查失败时同步脚本尚未运行，使用 runner 已遮蔽凭据的作业日志补足错误详情。
  let failureLog = '';
  if (env.SYNC_RESULT !== 'success') {
    const job = jobs.find(item => item.name === 'sync');
    if (job) {
      try {
        const response = await github.rest.actions.downloadJobLogsForWorkflowRun({
          ...context.repo, job_id: job.id,
        });
        if (typeof response.data === 'string') failureLog = redact(response.data).slice(-8000);
      } catch (error) {
        core.warning(`无法补充作业日志（HTTP ${error.status || 'unknown'}）；仍保存步骤和同步日志。`);
      }
    }
  }
  const issues = await github.paginate(github.rest.issues.listForRepo, {
    ...context.repo, state: 'open', creator: 'github-actions[bot]', per_page: 100,
  });
  const incident = issues.find(issue => !issue.pull_request && issue.title === title && issue.body?.includes(marker));
  const recoveredRetry = env.SYNC_RESULT === 'success' && Number(report.attempt || 1) > 1;
  if (env.SYNC_RESULT === 'success' && !recoveredRetry) {
    if (incident) {
      await github.rest.issues.createComment({ ...context.repo, issue_number: incident.number,
        body: `同步已恢复，远端校验通过。\n\n运行：${runUrl}\nmain: \`${report.remote_main || '见运行记录'}\`\ncustom: \`${report.remote_custom || '见运行记录'}\`` });
      await github.rest.issues.update({ ...context.repo, issue_number: incident.number, state: 'closed' });
    }
    core.info(incident ? '已记录恢复并关闭异常 Issue。' : '同步成功，没有待处理异常。');
    return;
  }
  const clean = value => redact(value || '未获取').replace(/```/g, '~~~').replace(/<!--|-->/g, '');
  const body = [marker,
    test ? '' : '@yyg20101',
    test ? '这是手动触发的异常上报测试，未执行分支同步。' : recoveredRetry ?
      '同步出现异常，重试后已恢复；保留下列诊断记录。' : '自动同步失败或取消，需要检查下列诊断记录。',
    `时间（UTC）：${new Date().toISOString()}`,
    `运行：${runUrl}（尝试 ${report.run_attempt || '1'}）`,
    `触发：${clean(report.event || env.TRIGGER_EVENT)}`,
    `工作流提交：\`${clean(report.workflow_sha || context.sha)}\``,
    `结果：${clean(env.SYNC_RESULT)}`,
    `阶段：${clean(report.stage)}；原因：${clean(report.reason)}；同步尝试：${clean(report.attempt)}`,
    `失败步骤：${failed.length ? clean(failed.join('; ')) : '查看运行链接；可能在初始化阶段失败'}`,
    '', '| 引用 | 提交 |', '| --- | --- |',
    ...['old_main', 'source_main', 'old_custom', 'new_custom', 'remote_main', 'remote_custom']
      .map(key => `| ${key} | ${clean(report[key])} |`),
    '', '冲突文件：', '```text', clean(report.conflicts || '无已记录的冲突'), '```',
    '', '同步日志尾部（最多 16000 字符）：', '```text', clean(report.log_tail || '脚本未执行；请检查上述失败步骤。'), '```',
    ...(failureLog ? ['', '失败作业日志尾部（最多 8000 字符）：', '```text', clean(failureLog), '```'] : []),
    '', '本记录保存在 Issue 中，不受 Auto-Clean 删除 Actions 运行记录的影响。',
  ].join('\n');
  let issue = incident;
  if (issue) {
    await github.rest.issues.createComment({ ...context.repo, issue_number: issue.number, body });
  } else {
    const response = await github.rest.issues.create({ ...context.repo, title, body });
    issue = response.data;
  }
  core.notice(`异常记录：${issue.html_url}`);
  if (test || recoveredRetry) {
    await github.rest.issues.createComment({ ...context.repo, issue_number: issue.number,
      body: test ? `诊断记录及 Issue 上报验证成功：${runUrl}。这是测试记录，现自动关闭。` :
        `重试后同步已恢复，远端校验通过：${runUrl}。异常日志保留，现自动关闭。` });
    await github.rest.issues.update({ ...context.repo, issue_number: issue.number, state: 'closed' });
  }
};
