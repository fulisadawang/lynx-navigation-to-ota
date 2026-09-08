#!/usr/bin/env node
import { CONTROL_HEADER, CONTROL_VALUE } from './server.mjs'

const endpoints = {
  state: ['GET', '/_fixture/state'], metrics: ['GET', '/_fixture/metrics'],
  reset: ['POST', '/_fixture/reset'], 'metrics-reset': ['POST', '/_fixture/metrics/reset'], stage: ['POST', '/_fixture/stage'], rule: ['POST', '/_fixture/rule'],
  fallback: ['POST', '/_fixture/fallback'], rollback: ['POST', '/_fixture/rollback'], publish: ['POST', '/_fixture/publish'],
  delay: ['POST', '/_fixture/delay-latest'], release: ['POST', '/_fixture/release-delays'],
}
try {
  const args = process.argv.slice(2)
  let origin = 'http://127.0.0.1:18766'
  if (args[0] === '--origin') { args.shift(); origin = args.shift() }
  const command = args.shift()
  if (!command || command === '--help') {
    console.log('node scripts/ota-user-gray/control.mjs [--origin http://127.0.0.1:18766] state|metrics|reset|metrics-reset|stage|rule|fallback|rollback|publish|delay|release [JSON]')
    process.exit(0)
  }
  if (!endpoints[command]) throw new Error('未知控制命令')
  const url = new URL(origin)
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.username || url.password) throw new Error('控制命令仅允许 localhost http origin')
  const [method, endpoint] = endpoints[command]
  const payload = args.length ? JSON.parse(args.join(' ')) : {}
  const response = await fetch(new URL(endpoint, url), {
    method, headers: { [CONTROL_HEADER]: CONTROL_VALUE, 'content-type': 'application/json' },
    ...(method === 'POST' ? { body: JSON.stringify(payload) } : {}),
  })
  const body = await response.json()
  console.log(JSON.stringify(body, null, 2))
  if (!response.ok) process.exitCode = 1
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
}
