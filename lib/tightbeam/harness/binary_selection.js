const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');
const {spawnSync} = require('node:child_process');
const [root, mode, argument] = process.argv.slice(1);
const started = Date.now();
const launch = mode === 'launch';
const pin = mode === 'pinned' ? argument :
  mode === 'remote' ? (process.env.TIGHTBEAM_DIAGNOSTIC_PIN || '') :
  (launch || mode === 'prospective') ? (process.env[pinName] || '') : '';
function lookup(name) {
  if (name.includes(path.sep)) return path.resolve(name);
  for (const directory of (process.env.PATH || '').split(path.delimiter)) {
    const candidate = path.resolve(directory, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (!fs.statSync(candidate).isDirectory()) return candidate;
    } catch {}
  }
  return null;
}
function real(file) {
  try { return fs.realpathSync(file); } catch { return null; }
}
function version(file, bundled) {
  // Only the default Codex bundle uses Node. Pins and PATH candidates retain
  // their executable/shebang semantics, even if their name ends in .js.
  const nodeBundle = bundled && vendor === 'codex';
  const out = spawnSync(nodeBundle ? process.execPath : file,
    nodeBundle ? [file, '--version'] : ['--version'],
    {encoding: 'utf8', timeout: 1200, env: process.env});
  return {ok: !out.error && out.status === 0,
    text: /\d+\.\d+(?:\.\d+)?/.test(out.stdout || out.stderr || '') ?
      (out.stdout || out.stderr).trim() : null,
    reason: out.error ? 'version invocation failed or exceeded 1200ms' :
      out.status === 0 ? null : 'version invocation exited unsuccessfully'};
}
let selected = pin || null;
let source = pin ? 'pinned_override' : 'bundled_fallback';
let bundled = null;
let response = null;
let fallbackReason = null;
try { bundled = bundle(); } catch {}
if (!pin) {
  const candidate = lookup(vendor);
  if (candidate) {
    const result = version(candidate, false);
    if (result.ok) {
      selected = candidate;
      response = result;
      const resolved = real(candidate);
      source = bundled && resolved && resolved === real(bundled) ? 'bundled_fallback' : 'system';
    } else {
      fallbackReason = result.reason;
    }
  } else {
    fallbackReason = 'host CLI is absent from the effective PATH';
  }
}
const invocation = selected || bundled;
if (!launch && !response && invocation) response = version(invocation, !selected);
const selection = {
  status: invocation ? 'observed' : 'missing', source,
  path: invocation, resolved_path: invocation ? real(lookup(invocation) || invocation) : null,
  version: response && response.ok ? response.text : null,
  version_status: response && response.ok && response.text ? 'observed' : 'unknown',
  reason: response && !response.ok ? response.reason :
    !invocation ? 'bundled CLI package is missing' : null,
  fallback_reason: fallbackReason
};
if (launch) {
  const capture = {selection, observation_started_at_ms: started,
    observation_completed_at_ms: Date.now(),
    evidence_boundary: 'Selection captured before adapter exec; version is selection-time evidence, not observed running vendor-child identity.'};
  process.stderr.write('TIGHTBEAM_VENDOR_SELECTION ' + JSON.stringify(capture) + '\n');
  const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
  // A bundle stays on the adapter's native default route. Explicit and automatic
  // invocations are passed intact; failures after this exec never select again.
  const env = selected ? [pinName + '=' + selected] : ['-u', pinName];
  process.stdout.write(['exec', '/usr/bin/env', ...env, argument].map(quote).join(' '));
} else {
  process.stdout.write(JSON.stringify(selection));
}
