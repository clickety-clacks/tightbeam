#!/usr/bin/env node
// Engine contract: Pi d57c2d21916eaad1158031526ac6ec860eae5f14.
// Automatic sources are bounded. This launcher neither reads nor rewrites prompts.
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ownedSkills = __TIGHTBEAM_OWNED_SKILLS__;

function existing(file) {
  try { return fs.realpathSync(file); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
function within(file, root) {
  const relative = path.relative(root, file);
  return relative === '' || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative));
}
function main() {
  const cwd = fs.realpathSync(process.cwd());
  const home = fs.realpathSync(process.env.PI_CODING_AGENT_DIR);
  const realHome = process.env.PI_REAL_HOME;
  if (!realHome || !path.isAbsolute(realHome)) throw new Error('Missing real Pi HOME');
  const extension = path.join(home, 'extensions', 'tightbeam.ts');
  if (!fs.statSync(extension).isFile()) throw new Error('Missing Tightbeam Pi extension');
  // Short switches are deliberately used: unsupported short options are errors,
  // not extension-defined long options. Never retry without these switches.
  const args = ['-nc', '-ns', '-ne', '-e', extension];
  const skills = new Set();
  function skillTree(root, boundary) {
    const visited = new Set();
    function walk(file) {
      const real = existing(file);
      if (!real || !within(real, boundary) || visited.has(real)) return;
      visited.add(real);
      if (fs.statSync(real).isDirectory()) {
        for (const name of fs.readdirSync(real).sort()) {
          if (!name.startsWith('.')) walk(path.join(real, name));
        }
      } else if (path.basename(real) === 'SKILL.md') skills.add(real);
    }
    walk(root);
  }
  // Only the baseline owned projections may resolve outside the shared home.
  // Their symlinks point at the packaged skills, not personal skill discovery.
  for (const name of ownedSkills) {
    const root = existing(path.join(home, 'skills', name));
    if (root) skillTree(root, root);
  }
  const visited = new Set();
  function workspace(dir) {
    const real = existing(dir);
    if (!real || !within(real, cwd) || visited.has(real)) return;
    visited.add(real);
    if (!fs.statSync(real).isDirectory()) return;
    // Match Pi's per-directory precedence while keeping every input in cwd.
    for (const name of ['AGENTS.override.md', 'AGENTS.md', 'AGENTS.MD', 'CLAUDE.md', 'CLAUDE.MD']) {
      const file = existing(path.join(real, name));
      if (file && within(file, cwd) && fs.statSync(file).isFile()) {
        args.push('--append-system-prompt', file);
        break;
      }
    }
    for (const name of ['.pi', '.agents']) skillTree(path.join(real, name, 'skills'), cwd);
    for (const name of fs.readdirSync(real).sort()) {
      if (!name.startsWith('.') && name !== 'node_modules') workspace(path.join(real, name));
    }
  }
  workspace(cwd);
  for (const file of [...skills].sort()) args.push('--skill', file);
  const childEnv = { ...process.env, HOME: realHome };
  delete childEnv.PI_REAL_HOME;
  const child = spawn('pi', [...args, ...process.argv.slice(2)], { stdio: 'inherit', env: childEnv });
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => child.kill(signal));
  child.on('error', error => { console.error(`Pi isolated launch failed: ${error.message}`); process.exitCode = 1; });
  child.on('exit', (code, signal) => {
    if (signal) { process.removeAllListeners(signal); process.kill(process.pid, signal); }
    else process.exitCode = code;
  });
}
try { main(); }
catch (error) { console.error(`Pi isolated launch refused: ${error.message}`); process.exitCode = 1; }
