import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

const [cli, ...args] = process.argv.slice(1);
const home = os.homedir();
const base = process.env.TIGHTBEAM_BASE_DIR ?? process.env.TIGHTBEAM_HOME ?? path.join(home, '.tightbeam');
const receiptPath = path.join(base, 'setup.json');
const mac = process.platform === 'darwin';
const account = os.userInfo();
const chatRoot = path.join(home, '.local/share/tightbeam-chat');
const chatCurrent = path.join(chatRoot, 'current');
const root = '/opt/tightbeam';
const env = { ...process.env, TIGHTBEAM_BASE_DIR: base };
for (const key of ['TIGHTBEAM_TOKEN', 'TIGHTBEAM_GATEWAY_URL', 'TIGHTBEAM_URL', 'TIGHTBEAM_SESSION', 'TIGHTBEAM_SESSION_FILE']) delete env[key];

function command(file, args, options = {}) {
  return spawnSync(file, args, { env, encoding: 'utf8', ...options });
}

function run(file, args, options = {}) {
  const result = command(file, args, { stdio: 'inherit', ...options });
  if (result.status !== 0) {
    throw new Error(`${path.basename(file)} failed${result.stderr?.trim() ? `: ${result.stderr.trim()}` : ''}`);
  }
  return result.stdout;
}

function available(file) {
  for (const directory of (env.PATH ?? '').split(path.delimiter)) {
    if (!path.isAbsolute(directory)) continue;
    try {
      const candidate = path.join(directory, file);
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {}
  }
}

function jsonFile(filename) {
  try {
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

function options() {
  let mode;
  let yes = false;
  let dryRun = false;
  for (let index = 0; index < args.length; index++) {
    switch (args[index]) {
      case '--mode':
        if (mode !== undefined) throw new Error('Specify --mode once.');
        mode = args[++index];
        if (!['quick', 'full'].includes(mode)) throw new Error('Choose --mode quick or --mode full.');
        break;
      case '--yes': yes = true; break;
      case '--dry-run': dryRun = true; break;
      default: throw new Error('Usage: tightbeam setup [--mode quick|full] [--yes] [--dry-run]');
    }
  }
  return { mode, yes, dryRun };
}

// Use one reader for both questions, including when answers are piped.
async function ask(iterator, prompt) {
  console.log(prompt);
  return (await iterator.next()).value?.trim().toLowerCase();
}

function service(kind, mode) {
  const system = mode === 'full' && kind === 'gateway';
  const linuxName = kind === 'gateway' ? 'tightbeam' : 'tightbeam-chat';
  const label = `com.tightbeam.${kind}`;
  const domain = system ? 'system' : `gui/${account.uid}`;
  const file = mac
    ? path.join(system ? '/Library/LaunchDaemons' : path.join(home, 'Library/LaunchAgents'), `${label}.plist`)
    : path.join(system ? '/etc/systemd/system' : path.join(home, '.config/systemd/user'), `${linuxName}.service`);
  const execute = (program, args, options) => system
    ? run('sudo', [program, ...args], options)
    : run(program, args, options);
  const systemctl = system ? [] : ['--user'];
  return {
    file,
    active: () => mac
      ? command('launchctl', ['print', `${domain}/${label}`]).status === 0
      : command('systemctl', [...systemctl, 'is-active', '--quiet', linuxName]).status === 0,
    enabled: () => mac
      ? fs.existsSync(file)
      : command('systemctl', [...systemctl, 'is-enabled', '--quiet', linuxName]).status === 0,
    install(contents, scratch, reload) {
      if (mac && reload) execute('launchctl', ['bootout', `${domain}/${label}`]);
      if (system) {
        const source = path.join(scratch, path.basename(file));
        fs.writeFileSync(source, contents);
        execute('install', ['-m', '0644', source, file]);
      } else {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, contents);
      }
      if (mac) execute('launchctl', ['bootstrap', domain, file]);
      else {
        execute('systemctl', [...systemctl, 'daemon-reload']);
        execute('systemctl', [...systemctl, 'enable', '--now', linuxName]);
        if (reload) execute('systemctl', [...systemctl, 'restart', linuxName]);
      }
    },
    start() {
      if (mac) execute('launchctl', ['kickstart', `${domain}/${label}`]);
      else execute('systemctl', [...systemctl, 'enable', '--now', linuxName]);
    },
    remove() {
      if (mac) {
        if (this.active()) execute('launchctl', ['bootout', `${domain}/${label}`]);
        fs.rmSync(file, { force: true });
      } else {
        execute('systemctl', [...systemctl, 'disable', '--now', linuxName]);
        fs.rmSync(file, { force: true });
        execute('systemctl', [...systemctl, 'daemon-reload']);
      }
    },
  };
}

function serviceContents(kind, mode, binary, args, variables, workingDir) {
  const system = kind === 'gateway' && mode === 'full';
  if (mac) {
    const xml = (value) => String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const string = (value) => `<string>${xml(value)}</string>`;
    const logBase = path.join(base, kind);
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key>${string(`com.tightbeam.${kind}`)}
${system ? `<key>UserName</key>${string(account.username)}` : ''}
<key>ProgramArguments</key><array>${[binary, ...args].map(string).join('')}</array>
<key>WorkingDirectory</key>${string(workingDir)}
<key>EnvironmentVariables</key><dict>
${Object.entries(variables).map(([key, value]) => `<key>${key}</key>${string(value)}`).join('\n')}
</dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ExitTimeOut</key><integer>120</integer>
<key>StandardOutPath</key>${string(`${logBase}.log`)}
<key>StandardErrorPath</key>${string(`${logBase}.err.log`)}
</dict></plist>
`;
  }

  const literal = (value) => JSON.stringify(value.replaceAll('%', '%%'));
  const execArg = (value) => literal(value.replaceAll('$', '$$'));
  return `[Unit]
Description=Tightbeam ${kind}
${system ? 'Wants=network-online.target\nAfter=network-online.target' : ''}
[Service]
Type=exec
${system ? `User=${account.uid}\nGroup=${account.gid}` : ''}
WorkingDirectory=${workingDir.replaceAll('%', '%%')}
ExecStart=${[binary, ...args].map(execArg).join(' ')}
${Object.entries(variables).map(([key, value]) => `Environment=${literal(`${key}=${value}`)}`).join('\n')}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=120s
OOMPolicy=continue

[Install]
WantedBy=${system ? 'multi-user.target' : 'default.target'}
`;
}

function fileMatches(file, contents) {
  try {
    return fs.readFileSync(file, 'utf8') === contents;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return false;
  }
}

async function download(url, destination) {
  run('curl', ['--fail', '--silent', '--show-error', '--location', '--max-time', '300', '--output', destination, url]);
}

async function releaseFiles(repository, tag, dir, selectAsset, sidecars) {
  const releases = `https://api.github.com/repos/clickety-clacks/${repository}/releases`;
  const data = path.join(dir, 'release.json');
  await download(`${releases}/${tag === 'latest' ? tag : `tags/${encodeURIComponent(tag)}`}`, data);
  const release = jsonFile(data);
  const asset = release.assets.find(({ name }) => selectAsset(name));
  if (!asset) throw new Error(`No suitable ${repository} package in ${release.tag_name}.`);
  for (const name of [asset.name, 'SHA256SUMS', ...sidecars]) {
    const item = release.assets.find((candidate) => candidate.name === name);
    if (!item) throw new Error(`${repository} release is missing ${name}.`);
    await download(item.browser_download_url, path.join(dir, name));
  }
  const file = path.join(dir, asset.name);
  const sums = fs.readFileSync(path.join(dir, 'SHA256SUMS'), 'utf8').split(/\r?\n/);
  const entry = sums.map((line) => line.match(/^([0-9a-f]{64})\s+\*?(.+)$/)).find((match) => match?.[2] === asset.name);
  const actual = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  if (actual !== entry?.[1]) throw new Error(`${repository} package checksum mismatch.`);
  return { file, digest: actual, tag: release.tag_name };
}

async function installChat(scratch) {
  const { file, digest } = await releaseFiles('tightbeam-chat', 'latest', scratch,
    (name) => /^tightbeam-chat-v\d+\.\d+\.\d+\.tar\.gz$/.test(name), []);
  const destination = path.join(chatRoot, `sha256-${digest}`);
  if (!fs.existsSync(destination)) {
    fs.mkdirSync(chatRoot, { recursive: true });
    const staging = fs.mkdtempSync(path.join(chatRoot, '.stage-'));
    try {
      run('tar', ['-xzf', file, '-C', staging]);
      fs.renameSync(staging, destination);
    } finally {
      fs.rmSync(staging, { recursive: true, force: true });
    }
  }
  fs.symlinkSync(destination, chatCurrent);
}

async function stageGateway(scratch, release, activate) {
  const platform = mac ? 'darwin-aarch64' : 'linux-x86_64';
  const version = release.tag.match(/^v([^+]+)/)[1];
  const name = `tightbeam-${version}-${platform}-${release.commit.slice(0, 7)}.tgz`;
  const directory = env.TIGHTBEAM_SETUP_RELEASE_DIR ?? scratch;
  const provenance = path.join(directory, 'release-provenance.json');
  const checksums = path.join(directory, 'SHA256SUMS');
  let file;
  if (directory === scratch) {
    ({ file } = await releaseFiles('tightbeam', release.tag, scratch,
      (asset) => asset === name, ['release-provenance.json']));
  } else {
    file = path.resolve(directory, name);
  }
  const identity = jsonFile(provenance);
  if (identity?.commit !== release.commit || identity.tag !== release.tag) {
    throw new Error('The verified installation package must match the running Tightbeam release.');
  }
  const digest = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const selector = path.join(path.dirname(cli), 'tightbeam-select');
  const sudo = (args) => run('sudo', [process.execPath, selector, ...args]);
  sudo(['stage', '--root', root, '--package', file, '--checksums', path.resolve(checksums),
    '--provenance', path.resolve(provenance)]);
  activate();
  sudo(['select', '--root', root, '--build', `sha256-${digest}`, '--base-dir', base]);
}

async function getJson(url, token, timeout = 1500) {
  try {
    const response = await fetch(url, {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      signal: AbortSignal.timeout(timeout),
    });
    if (response.ok) return await response.json();
  } catch {}
}

async function waitFor(read, message) {
  for (let attempt = 0; attempt < 120; attempt++) {
    const result = await read();
    if (result) return result;
    await delay(500);
  }
  throw new Error(message);
}

function providerActions(host) {
  return [
    ['claude', 'anthropic', 'ANTHROPIC_API_KEY'],
    ['codex', 'openai', 'OPENAI_API_KEY'],
    ['pi', 'opencode-go', 'OPENCODE_API_KEY'],
    ['cursor', 'cursor', 'CURSOR_API_KEY'],
  ].filter(([harness]) => available(harness))
    .map(([harness, provider, key]) => {
      const metadata = jsonFile(path.join(base, 'homes', host, harness, '.tightbeam', 'credential.json'));
      return { provider, key, needed: !metadata?.onboarded || metadata.terminal === true };
    });
}

function gatewayFrame(origin, request, type) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`${origin.replace(/^http/, 'ws')}/ws`);
    const timeout = setTimeout(() => finish(new Error('Tightbeam did not answer the local Chat setup request.')), 15000);
    function finish(error, result) {
      clearTimeout(timeout);
      socket.close();
      if (error) reject(error);
      else resolve(result);
    }
    socket.onopen = () => socket.send(JSON.stringify({ protocolVersion: 1, ...request }));
    socket.onerror = () => finish(new Error('Chat setup could not connect to the local gateway.'));
    socket.onmessage = ({ data }) => {
      const frame = JSON.parse(data);
      if (frame.type === type) finish(undefined, frame);
      if (frame.type === 'error') finish(new Error('The gateway refused the local Chat setup request.'));
    };
  });
}

async function pairFirstUser(localOrigin, deviceId, claimedName) {
  const pair = () => gatewayFrame(localOrigin, { type: 'pair_request', deviceId, claimedName }, 'pair_result');
  let result = await pair();
  if (result.reason === 'pair_pending') {
    run(cli, ['approve-device', deviceId, '--as-user', claimedName], { cwd: home });
    result = await pair();
  }
  if (!result.success || !result.token) throw new Error('Could not pair the local Chat client.');
  return result;
}

async function setup() {
  const flags = options();
  let { mode } = flags;
  const reader = createInterface({ input: process.stdin, terminal: false, crlfDelay: Infinity });
  const answers = reader[Symbol.asyncIterator]();
  try {
    if (!mode) {
      mode = await ask(answers, 'Choose quick or full');
      if (!['quick', 'full'].includes(mode)) return;
    }

    const receipt = jsonFile(receiptPath);
    if (account.uid === 0) throw new Error('Run setup from your ordinary user account. Full setup requests sudo when needed.');
    if (!mac && process.platform !== 'linux') throw new Error('Setup supports macOS and Linux.');
    if (!path.isAbsolute(base) || /[\r\n]/.test(base)) throw new Error('Use an absolute Tightbeam base directory.');
    if (receipt && !['quick', 'full'].includes(receipt.mode)) throw new Error('The setup receipt has an unknown service mode.');
    if (!receipt && fs.existsSync(path.join(base, 'state.db'))) {
      throw new Error('This base directory already contains a Tightbeam installation managed outside setup.');
    }
    if (receipt?.mode === 'full' && mode === 'quick') throw new Error('This installation uses full mode. Run setup in full mode.');

    const host = receipt?.host ?? env.TIGHTBEAM_LOCAL_HOST_NAME ?? os.hostname();
    if (!host || host.includes('/') || ['.', '..'].includes(host)) throw new Error('Choose a valid local host name.');
    const port = Number(receipt?.port ?? env.TIGHTBEAM_PORT ?? '11373');
    if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error('Choose a valid gateway port.');
    const localOrigin = `http://127.0.0.1:${port}`;
    const advertised = mode === 'quick' ? localOrigin
      : env.TIGHTBEAM_ADVERTISED_URL ?? receipt?.advertised ?? localOrigin;
    const chatOrigin = new URL(advertised.replace(/^ws/, 'http')).origin;
    const version = run(cli, ['--version'], { stdio: 'pipe' }).trim();
    const upgrade = receipt?.mode === 'quick' && mode === 'full';
    const gateway = service('gateway', mode);
    const quickGateway = service('gateway', 'quick');
    const chat = service('chat', 'quick');
    const release = jsonFile(path.join(path.dirname(cli), '../setup-build.json'));
    const tag = release?.tag;
    const stage = mode === 'full' && (receipt?.mode !== 'full' || receipt.tag !== tag);
    const credentials = path.join(base, 'setup-device-token');
    const needsPair = !fs.existsSync(credentials);
    const needsMain = !receipt?.main;
    const binary = mode === 'full'
      ? path.join(root, 'current/tightbeam/bin/tightbeam-gateway')
      : path.join(path.dirname(cli), 'tightbeam-gateway');

    const variables = {
      HOME: home,
      PATH: env.PATH,
      TIGHTBEAM_BASE_DIR: base,
      TIGHTBEAM_LOCAL_HOST_NAME: host,
      TIGHTBEAM_PORT: String(port),
      TIGHTBEAM_ADVERTISED_URL: advertised,
    };
    if (mode === 'quick') variables.TIGHTBEAM_LOOPBACK_ONLY = 'true';
    for (const key of ['TIGHTBEAM_DEFAULT_HARNESS', 'TIGHTBEAM_DEFAULT_MODEL', 'TIGHTBEAM_DEFAULT_EFFORT',
      'TIGHTBEAM_DEFAULT_CONTEXT', 'TIGHTBEAM_CREDENTIALS_DIRECTORY', 'CODEX_PATH']) {
      if (env[key]) variables[key] = env[key];
    }

    const gatewayFile = serviceContents('gateway', mode, binary, [], variables, home);
    const writeGateway = !fs.existsSync(gateway.file) || (upgrade && !fileMatches(gateway.file, gatewayFile));
    const gatewayActive = gateway.active();
    const startGateway = !gatewayActive || !gateway.enabled();
    const installChatPackage = !fs.existsSync(path.join(chatCurrent, 'server/chat-server.mjs'));
    const chatConfigChanged = !receipt?.main || receipt.advertised !== advertised;
    const chatActive = chat.active();
    const chatFile = (main, admin) => serviceContents('chat', 'quick', process.execPath,
      [path.join(chatCurrent, 'server/chat-server.mjs')], {
        HOME: home, PATH: env.PATH, TIGHTBEAM_BASE_DIR: base,
        CHAT_DEFAULT_GATEWAY_ORIGIN: chatOrigin, CHAT_DEFAULT_SESSION_KEY: main,
        CHAT_DEFAULT_PRINCIPAL_KEY: admin, CHAT_READ_MARKER_DEVICE_CREDENTIAL_FILE: credentials,
      }, chatCurrent);
    const writeChat = chatConfigChanged || !fs.existsSync(chat.file);
    const startChat = !chatActive || !chat.enabled();
    const providers = providerActions(host);
    const pending = providers.filter(({ needed }) => needed);
    const needsFirstRun = command(cli, ['onboard', '--first-run', '--check'], { cwd: home }).status === 0;
    const bwrap = available('bwrap');
    const canBubblewrap = () => command(bwrap, ['--unshare-net', '--ro-bind', '/', '/', '/bin/true']).status === 0;
    const readSysctl = (key) => command('sysctl', ['-n', key]).stdout?.trim();
    const checkNamespaces = !mac && mode === 'full' && providers.some(({ provider }) => provider === 'openai');
    const namespaceFix = checkNamespaces && bwrap && !canBubblewrap();
    const appArmor = namespaceFix && readSysctl('kernel.apparmor_restrict_unprivileged_userns') === '1';
    const sysctlKey = namespaceFix && [
      'kernel.unprivileged_userns_clone', 'user.max_user_namespaces',
    ].find((key) => readSysctl(key) === '0');
    const install = [];
    const add = (when, text) => { if (when) install.push(text); };
    const missing = ['git', 'npm', 'curl', 'tar'].filter((name) => !available(name));
    if (!providers.length) missing.push('at least one supported harness CLI (claude, codex, pi, or cursor)');
    if (!['darwin', 'linux'].includes(process.platform)) missing.push('a supported operating system');
    if (Number(process.versions.node.split('.')[0]) < 24) missing.push('Node.js 24 or later');
    if (mode === 'full' && !available('sudo')) missing.push('sudo');
    if (checkNamespaces && !bwrap) missing.push('bubblewrap');
    if (!stage && !fs.existsSync(binary)) missing.push('the bundled tightbeam-gateway binary');
    if (!mac && command('systemctl', ['--user', 'show-environment']).status !== 0) missing.push('a running systemd user manager');
    if (mac && command('launchctl', ['print', `gui/${account.uid}`]).status !== 0) missing.push('a logged-in macOS desktop session');
    add(missing.length, `Check missing prerequisites: ${missing.join(', ')}.`);
    add(stage, 'Verify and stage the Tightbeam release under /opt/tightbeam and select it for the system service.');
    add(appArmor, 'Grant bubblewrap access to user namespaces through its AppArmor profile.');
    add(namespaceFix && !appArmor && sysctlKey, `Enable Linux user namespaces through ${sysctlKey} for the Codex sandbox.`);
    add(namespaceFix && !appArmor && !sysctlKey, 'Check why the Codex sandbox cannot start on this Linux machine.');
    add(upgrade, `Replace the user gateway service with a system service while keeping all data in ${base}.`);
    add(writeGateway || startGateway, mode === 'quick'
      ? 'Start Tightbeam as a local-only user service with lighter isolation than full mode.'
      : 'Start Tightbeam as a system service that runs your agents under your ordinary user account.');
    add(needsPair, `Pair this computer and create the first Tightbeam administrator for ${account.username}.`);
    for (const { provider } of pending) add(true, `Set up your ${provider} credential for agent turns.`);
    add(needsMain, 'Create your main Tightbeam conversation.');
    add(installChatPackage, 'Download and verify the published Tightbeam Chat package.');
    add(writeChat || startChat, 'Start Tightbeam Chat on this machine as a user service.');
    add(needsFirstRun, 'Open Tightbeam Chat and ask your main agent to introduce itself.');
    for (const line of install) console.log(`- ${line}`);
    if (flags.dryRun) return;
    if (!flags.yes && await ask(answers, 'Install yes or no') !== 'yes') return;
    reader.close();
    process.stdin.pause();

    if (missing.length) throw new Error(`Install the missing prerequisites and run setup again: ${missing.join(', ')}.`);
    if (!install.length) return;
    if (stage && (!/^v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$/.test(tag ?? '') ||
        !/^[0-9a-f]{40}$/.test(release?.commit ?? ''))) {
      throw new Error('Full setup needs a release package with its exact published release provenance.');
    }
    if (!receipt && (gatewayActive || fs.existsSync(gateway.file) || quickGateway.active() || fs.existsSync(quickGateway.file))) {
      throw new Error('A Tightbeam service already exists outside setup. Use its existing installation procedure.');
    }

    fs.mkdirSync(base, { recursive: true, mode: 0o700 });
    const state = { ...receipt, mode: receipt?.mode ?? mode, host, port };
    const save = () => {
      const temporary = `${receiptPath}.${process.pid}`;
      fs.writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
      fs.renameSync(temporary, receiptPath);
    };
    state.deviceId ??= `setup_${randomUUID()}`;
    state.admin ??= account.username;
    save();
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'tightbeam-setup-'));
    let removedQuick = false;
    try {
      if (appArmor) {
        const profile = '/etc/apparmor.d/bwrap';
        if (fs.existsSync(profile)) throw new Error(`The existing ${profile} needs attention before the Codex sandbox can start.`);
        const source = path.join(scratch, 'bwrap');
        fs.writeFileSync(source, 'abi <abi/4.0>,\ninclude <tunables/global>\n\nprofile bwrap /usr/bin/bwrap flags=(unconfined) {\n  userns,\n  include if exists <local/bwrap>\n}\n');
        run('sudo', ['apparmor_parser', '-Q', source]);
        run('sudo', ['install', '-m', '0644', source, profile]);
        run('sudo', ['apparmor_parser', '-r', profile]);
      } else if (sysctlKey) {
        const value = sysctlKey === 'user.max_user_namespaces' ? '15000' : '1';
        const source = path.join(scratch, 'userns.conf');
        fs.writeFileSync(source, `${sysctlKey} = ${value}\n`);
        const conf = '/etc/sysctl.d/70-tightbeam-userns.conf';
        run('sudo', ['install', '-m', '0644', source, conf]);
        run('sudo', ['sysctl', '-p', conf]);
      }
      if (checkNamespaces && !canBubblewrap()) throw new Error('The Linux Codex sandbox still cannot create a user namespace.');
      if (stage) await stageGateway(scratch, release, () => {
        if (upgrade) {
          state.gatewayFile ??= fs.readFileSync(quickGateway.file, 'utf8');
          save();
          quickGateway.remove();
          removedQuick = true;
        }
      });
      if (writeGateway || stage || (mac && startGateway)) gateway.install(gatewayFile, scratch, gatewayActive);
      else if (startGateway) gateway.start();
      await waitFor(async () => {
        const descriptor = jsonFile(path.join(base, 'gateway.json'));
        const response = await getJson(`${localOrigin}/version`);
        return descriptor?.port === port && response?.server === 'tightbeam' && response.version === version;
      }, 'The gateway did not become ready. Check the service log and run setup again.');
      Object.assign(state, { mode, version, advertised, tag });
      save();

      if (needsPair) {
        const result = await pairFirstUser(localOrigin, state.deviceId, state.admin);
        if (result.userId !== state.admin) throw new Error('The local Chat client paired with an unexpected account.');
        fs.writeFileSync(credentials, result.token, { flag: 'wx', mode: 0o600 });
      }
      for (const { provider, key } of pending) {
        const onboard = ['onboard', provider, '--as-user', state.admin];
        if (env[key]) {
          run(cli, [...onboard, '--api-key'], { input: env[key], stdio: ['pipe', 'inherit', 'inherit'], cwd: home });
        } else if (provider === 'opencode-go' && env.TIGHTBEAM_CREDENTIALS_DIRECTORY) {
          run(cli, [...onboard, '--daemon-credential'], { cwd: home });
        } else if (provider === 'openai' || provider === 'anthropic') {
          run(cli, onboard, { cwd: home });
        } else {
          throw new Error(`Set ${key} to onboard ${provider}, then run setup again.`);
        }
      }
      if (installChatPackage) await installChat(scratch);
      if (needsMain) {
        const auth = await gatewayFrame(localOrigin, {
          type: 'auth', deviceId: state.deviceId, token: fs.readFileSync(credentials, 'utf8'), subscriptions: ['chat'],
        }, 'auth_result');
        if (!auth.success) throw new Error('Could not set up the main Tightbeam session.');
        const streams = await getJson(`${localOrigin}/api/streams`, fs.readFileSync(credentials, 'utf8'));
        state.main = streams?.streams?.find((stream) => stream.kind === 'main')?.sessionKey;
        if (!state.main) throw new Error('Could not find the main Tightbeam session.');
        save();
      }
      if (writeChat || (mac && startChat)) {
        chat.install(chatFile(state.main, state.admin), scratch, chatActive);
      } else if (startChat) {
        chat.start();
      }
      await waitFor(() => getJson('http://127.0.0.1:4178/chat-config.json'), 'Chat did not become ready. Check its service log.');
      console.log('Tightbeam Chat is ready at http://127.0.0.1:4178');
      if (command(cli, ['onboard', '--first-run', '--check'], { cwd: home }).status === 0) {
        run(cli, ['onboard', '--first-run'], { cwd: home });
      }
    } catch (error) {
      if (removedQuick && !gateway.active() && state.gatewayFile) {
        quickGateway.install(state.gatewayFile, scratch, false);
      }
      throw error;
    } finally {
      fs.rmSync(scratch, { recursive: true, force: true });
    }
  } finally {
    reader.close();
  }
}

setup().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
