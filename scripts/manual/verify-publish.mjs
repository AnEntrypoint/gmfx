import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const workflowArg = args.find((arg) => arg.startsWith('--workflow='))
const workflow = workflowArg ? workflowArg.slice('--workflow='.length) : 'publish-libfx.yml'
const root = path.resolve(args.find((arg) => !arg.startsWith('--')) || '.')
const workflowFile = path.resolve(root, '.github', 'workflows', workflow)
if (!existsSync(workflowFile)) {
  console.error('verify-publish.mjs: workflow file not found at ' + workflowFile + '. Pass --workflow=<name or path> to choose another workflow.')
  process.exit(1)
}
const run = (cmd) => execFileSync(cmd[0], cmd.slice(1), { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()

const head = run(['git', 'rev-parse', 'HEAD'])
const runs = JSON.parse(run(['gh', 'run', 'list', '--workflow', workflow, '--branch', 'main', '--limit', '20', '--json', 'headSha,status,conclusion,url']))
const match = runs.find((item) => item.headSha === head)
const result = match
  ? { ok: match.status === 'completed' && match.conclusion === 'success', head, status: match.status, conclusion: match.conclusion, url: match.url }
  : { ok: false, head, status: 'no run for this commit' }
console.log(JSON.stringify(result))
if (!result.ok) process.exitCode = 1
