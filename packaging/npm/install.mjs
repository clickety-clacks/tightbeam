#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants, createWriteStream, realpathSync } from 'node:fs';
import { access, mkdir, mkdtemp, readFile, rename, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import { archives, platforms, releaseIdentity, releaseUrl } from './release.mjs';

async function download(url, request) {
  const response = await request(url, { signal: AbortSignal.timeout(300_000) });
  if (!response.ok) throw new Error('Download failed (HTTP ' + response.status + '): ' + url);
  return response;
}

export async function install({ tag, platform, home, request = fetch }) {
  const checksums = await download(releaseUrl(tag, 'SHA256SUMS'), request)
    .then(response => response.text());
  const { name, sha256 } = archives(tag, checksums)[platform];
  const root = join(home, '.local', 'share', 'tightbeam-install');
  await mkdir(root, { recursive: true });
  const stage = await mkdtemp(join(root, '.download-'));
  try {
    const archive = join(stage, name);
    const hash = createHash('sha256');
    const digest = new Transform({
      transform(chunk, _encoding, callback) {
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    const response = await download(releaseUrl(tag, name), request);
    await pipeline(response.body, digest, createWriteStream(archive, { flags: 'wx' }));
    if (hash.digest('hex') !== sha256) throw new Error('SHA-256 mismatch for ' + name);

    const result = spawnSync('tar', ['-xzf', archive, '-C', stage], { stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error('Could not unpack ' + name);

    const payload = join(stage, 'tightbeam');
    await access(join(payload, 'bin', 'tightbeam'), constants.X_OK);
    const destination = join(root, sha256);
    try {
      await rename(payload, destination);
    } catch (error) {
      // A previous invocation may already have installed these exact bytes.
      if (!['EEXIST', 'ENOTEMPTY'].includes(error.code)) throw error;
    }
    return join(destination, 'bin', 'tightbeam');
  } finally {
    await rm(stage, { recursive: true, force: true });
  }
}

async function main() {
  const manifest = JSON.parse(await readFile(new URL('./package.json', import.meta.url), 'utf8'));
  const tag = manifest.tightbeamRelease;
  if (releaseIdentity(tag).npmVersion !== manifest.version) {
    throw new Error('npm version and GitHub release tag disagree');
  }
  const platform = process.platform + '-' + process.arch;
  if (!Object.hasOwn(platforms, platform)) {
    throw new Error('Unsupported platform: ' + platform + ' (supported: macOS arm64 and Linux x86_64)');
  }
  const executable = await install({ tag, platform, home: homedir() });
  console.error('Installed Tightbeam ' + tag + ' at ' + executable);
  const result = spawnSync(executable, ['setup', ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: { ...process.env, PATH: dirname(executable) + ':' + (process.env.PATH ?? '') },
  });
  if (result.error) throw result.error;
  if (result.signal) process.kill(process.pid, result.signal);
  process.exitCode = result.status ?? 1;
}

// npm invokes the executable through a symlink.
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    console.error('tightbeam: ' + error.message);
    process.exitCode = 1;
  });
}
