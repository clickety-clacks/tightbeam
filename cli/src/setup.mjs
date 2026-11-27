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
const quickRoot = path.join(home, '.local/share/tightbeam');
const chatUrl = 'http://127.0.0.1:4178';
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
        execute('rm', ['-f', file]);
      } else {
        if (this.active() || this.enabled()) execute('systemctl', [...systemctl, 'disable', '--now', linuxName]);
        execute('rm', ['-f', file]);
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

function download(url, destination) {
  try {
    run('curl', ['--fail', '--silent', '--show-error', '--location', '--max-time', '300', '--output', destination, url]);
  } catch (error) {
    throw new Error(`Could not download ${url}: ${error.message}`);
  }
}

function checksumEntries(file) {
  return fs.readFileSync(file, 'utf8').split(/\r?\n/)
    .map((line) => line.match(/^([0-9a-f]{64})\s+\*?(.+)$/))
    .filter(Boolean);
}

function installChat(scratch) {
  const releases = 'https://github.com/clickety-clacks/tightbeam-chat/releases';
  const sums = path.join(scratch, 'chat-SHA256SUMS');
  download(`${releases}/latest/download/SHA256SUMS`, sums);
  const packages = checksumEntries(sums).filter((entry) =>
    /^tightbeam-chat-v\d+\.\d+\.\d+\.tar\.gz$/.test(entry[2]));
  if (packages.length !== 1) throw new Error('The Chat release must provide one package checksum.');
  const [, expected, name] = packages[0];
  const tag = name.slice('tightbeam-chat-'.length, -'.tar.gz'.length);
  const file = path.join(scratch, name);
  download(`${releases}/download/${tag}/${name}`, file);
  const digest = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  if (digest !== expected) throw new Error('Tightbeam Chat package checksum mismatch.');
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
  selectLink(chatCurrent, destination);
}

function linkTarget(link) {
  try {
    return fs.readlinkSync(link);
  } catch (error) {
    if (error.code !== 'ENOENT') throw new Error(`An unmanaged file already exists at ${link}.`);
  }
}

function selectLink(link, target) {
  fs.mkdirSync(path.dirname(link), { recursive: true });
  const staging = `${link}.setup-${randomUUID()}`;
  try {
    fs.symlinkSync(target, staging);
    fs.renameSync(staging, link);
  } finally {
    fs.rmSync(staging, { force: true });
  }
}

function installQuick(payload, release) {
  const builds = path.join(quickRoot, 'builds');
  const target = path.join(builds, release.commit);
  fs.mkdirSync(builds, { recursive: true });
  if (!fs.existsSync(target)) {
    const staging = fs.mkdtempSync(path.join(builds, '.stage-'));
    try {
      fs.cpSync(payload, staging, { recursive: true, verbatimSymlinks: true });
      fs.renameSync(staging, target);
    } finally {
      fs.rmSync(staging, { recursive: true, force: true });
    }
  }
  selectLink(path.join(quickRoot, 'current'), target);
}

function appArmorProfile(bwrap) {
  return `abi <abi/4.0>,\ninclude <tunables/global>\n\nprofile bwrap ${JSON.stringify(bwrap)} flags=(unconfined) {\n  userns,\n  include if exists <local/bwrap>\n}\n`;
}

function shellQuote(value) {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

function primaryAddress() {
  return Object.values(os.networkInterfaces()).flat().find(
    (item) => item.family === 'IPv4' && !item.internal,
  )?.address ?? os.hostname();
}

async function stageGateway(scratch, release, activate) {
  const platform = mac ? 'darwin-aarch64' : 'linux-x86_64';
  const version = release.tag.match(/^v([^+]+)/)[1];
  const name = `tightbeam-${version}-${platform}-${release.commit.slice(0, 7)}.tgz`;
  const directory = env.TIGHTBEAM_SETUP_RELEASE_DIR ?? scratch;
  const provenance = path.join(directory, 'release-provenance.json');
  const checksums = path.join(directory, 'SHA256SUMS');
  const file = path.resolve(directory, name);
  if (directory === scratch) {
    const url = `https://github.com/clickety-clacks/tightbeam/releases/download/${release.tag}`;
    download(`${url}/SHA256SUMS`, checksums);
    download(`${url}/release-provenance.json`, provenance);
    download(`${url}/${name}`, file);
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
    env.TIGHTBEAM_LOCAL_OPENAI_ENDPOINT
      ? ['pi', 'local-openai', 'LOCAL_OPENAI_API_KEY']
      : ['pi', 'opencode-go', 'OPENCODE_API_KEY'],
    ['cursor', 'cursor', 'CURSOR_API_KEY'],
  ].filter(([harness]) => available(harness))
    .map(([harness, provider, key]) => {
      const file = provider === 'local-openai' ? 'local-openai-credential.json' : 'credential.json';
      const metadata = jsonFile(path.join(base, 'homes', host, harness, '.tightbeam', file));
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
  const result = await gatewayFrame(localOrigin, { type: 'pair_request', deviceId, claimedName }, 'pair_result');
  if (result.reason === 'pair_pending') {
    throw new Error('An administrator already exists. Approve the local Chat device and rerun setup.');
  }
  if (!result.success || !result.token || !result.userId) throw new Error('Could not pair the local Chat client.');
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
      : env.TIGHTBEAM_ADVERTISED_URL ?? (receipt?.mode === 'full' ? receipt.advertised : undefined) ?? `http://${primaryAddress()}:${port}`;
    const advertisedOrigin = new URL(advertised.replace(/^ws/, 'http')).origin;
    const chatOrigin = localOrigin;
    const chatMapFile = mode === 'full' ? path.join(base, 'setup-chat-gateways.json') : undefined;
    const aliases = advertisedOrigin === localOrigin ? [] : [advertisedOrigin];
    const chatMap = chatMapFile && { version: 1, gateways: [{ origin: localOrigin, baseDir: base, aliases }] };
    const writeChatMap = chatMapFile && JSON.stringify(jsonFile(chatMapFile)) !== JSON.stringify(chatMap);
    const version = run(cli, ['--version'], { stdio: 'pipe' }).trim();
    const upgrade = receipt?.mode === 'quick' && mode === 'full';
    const gateway = service('gateway', mode);
    const quickGateway = service('gateway', 'quick');
    const chat = service('chat', 'quick');
    const payload = path.resolve(path.dirname(cli), '..');
    const release = jsonFile(path.join(payload, 'setup-build.json'));
    const tag = release?.tag;
    const versionChanged = Boolean(receipt?.tag && receipt.tag !== tag);
    if (receipt?.mode === 'full' && versionChanged) {
      throw new Error('Back up and upgrade the existing full installation using the Tightbeam upgrade procedure at https://github.com/clickety-clacks/tightbeam/blob/main/docs/UPGRADE.md.');
    }
    if (upgrade && versionChanged) {
      throw new Error('Run tightbeam setup --mode quick with this release before converting your installation to full mode.');
    }
    const stage = mode === 'full' && (receipt?.mode !== 'full' ||
      !fs.existsSync(path.join(root, 'current/tightbeam/bin/tightbeam-gateway')));
    const credentials = path.join(base, 'setup-device-token');
    const needsPair = !fs.existsSync(credentials);
    const needsMain = !receipt?.main;
    const stableBin = mode === 'full' ? path.join(root, 'current/tightbeam/bin') : path.join(quickRoot, 'current/bin');
    const binary = path.join(stableBin, 'tightbeam-gateway');
    const quickLink = path.join(quickRoot, 'current');
    const quickPayload = release && path.join(quickRoot, 'builds', release.commit);
    const stageQuick = mode === 'quick' &&
      (!quickPayload || linkTarget(quickLink) !== quickPayload || !fs.existsSync(binary));
    const commandLink = path.join(home, '.local/bin/tightbeam');
    const targetCli = path.join(stableBin, 'tightbeam');
    const currentCommand = linkTarget(commandLink);
    if (currentCommand && ![path.join(root, 'current/tightbeam/bin/tightbeam'),
      path.join(quickRoot, 'current/bin/tightbeam')].includes(currentCommand)) {
      throw new Error(`An unmanaged Tightbeam command already exists at ${commandLink}.`);
    }
    const linkCli = currentCommand !== targetCli;

    const variables = {
      HOME: home,
      PATH: env.PATH,
      TIGHTBEAM_BASE_DIR: base,
      TIGHTBEAM_LOCAL_HOST_NAME: host,
      TIGHTBEAM_PORT: String(port),
      TIGHTBEAM_ADVERTISED_URL: advertised,
    };
    if (mode === 'quick') variables.TIGHTBEAM_LOOPBACK_ONLY = 'true';
    if (receipt?.defaultHarness) variables.TIGHTBEAM_DEFAULT_HARNESS = receipt.defaultHarness;
    for (const key of ['TIGHTBEAM_DEFAULT_HARNESS', 'TIGHTBEAM_DEFAULT_MODEL', 'TIGHTBEAM_DEFAULT_EFFORT',
      'TIGHTBEAM_DEFAULT_CONTEXT', 'TIGHTBEAM_CREDENTIALS_DIRECTORY', 'CODEX_PATH', 'TIGHTBEAM_FIRST_RUN_ONBOARDING']) {
      if (env[key]) variables[key] = env[key];
    }

    const gatewayActive = gateway.active();
    const startGateway = !gatewayActive || !gateway.enabled();
    const installChatPackage = !fs.existsSync(path.join(chatCurrent, 'server/chat-server.mjs'));
    const chatConfigChanged = !receipt?.main || receipt.advertised !== advertised;
    const chatActive = chat.active();
    const chatFile = (main, admin) => serviceContents('chat', 'quick', process.execPath,
      ['--preserve-symlinks-main', path.join(chatCurrent, 'server/chat-server.mjs')], {
        HOME: home, PATH: env.PATH, TIGHTBEAM_BASE_DIR: base,
        CHAT_PUBLIC_ORIGIN: chatUrl, CHAT_DEFAULT_GATEWAY_ORIGIN: chatOrigin, CHAT_DEFAULT_SESSION_KEY: main,
        CHAT_DEFAULT_PRINCIPAL_KEY: admin, CHAT_READ_MARKER_DEVICE_CREDENTIAL_FILE: credentials,
        ...(chatMapFile ? { CHAT_GATEWAY_MAP_FILE: chatMapFile } : {}),
      }, chatCurrent);
    const writeChat = chatConfigChanged || !fs.existsSync(chat.file) || receipt?.chatOrigin !== chatOrigin || writeChatMap;
    const startChat = !chatActive || !chat.enabled();
    const providers = providerActions(host);
    const withoutKeys = providers.filter(({ provider, key, needed }) => needed && !env[key] &&
      (provider === 'cursor' || (provider === 'opencode-go' && !env.TIGHTBEAM_CREDENTIALS_DIRECTORY) ||
        (!process.stdin.isTTY && ['openai', 'anthropic'].includes(provider))));
    const eligible = providers.filter((provider) => !withoutKeys.includes(provider));
    const pending = eligible.filter(({ needed }) => needed);
    const onboardingEnv = {
      ...env,
      TIGHTBEAM_CHAT_URL: chatUrl,
      CHAT_PUBLIC_ORIGIN: chatUrl,
    };
    if (chatMapFile) onboardingEnv.CHAT_GATEWAY_MAP_FILE = chatMapFile;
    else delete onboardingEnv.CHAT_GATEWAY_MAP_FILE;
    const needsFirstRun = command(cli, ['onboard', '--first-run', '--check'], { cwd: home, env: onboardingEnv }).status === 0;
    const bwrap = available('bwrap');
    const canBubblewrap = () => command(bwrap, ['--unshare-net', '--ro-bind', '/', '/', '/bin/true']).status === 0;
    const readSysctl = (key) => command('sysctl', ['-n', key]).stdout?.trim();
    const checkNamespaces = !mac && providers.some(({ provider }) => provider === 'openai');
    const sandboxUnavailable = checkNamespaces && (!bwrap || !canBubblewrap());
    const needsAppArmor = sandboxUnavailable && bwrap &&
      readSysctl('kernel.apparmor_restrict_unprivileged_userns') === '1';
    const usernsLimit = sandboxUnavailable && bwrap && [
      'kernel.unprivileged_userns_clone', 'user.max_user_namespaces',
    ].find((key) => readSysctl(key) === '0');
    const namespaceFix = mode === 'full' && Boolean(needsAppArmor || usernsLimit);
    const readiness = !receipt?.ready || versionChanged;
    const codexDisabled = sandboxUnavailable && !namespaceFix;
    const writeGateway = !fs.existsSync(gateway.file) || upgrade || receipt?.advertised !== advertised ||
      versionChanged || receipt?.codexDisabled !== codexDisabled || namespaceFix;
    const appArmor = namespaceFix && needsAppArmor;
    const sysctlKey = namespaceFix && usernsLimit;
    const lingering = !mac && command('loginctl', ['show-user', account.username, '--property=Linger', '--value']).stdout?.trim() === 'yes';
    const enableLinger = !mac && !lingering && !receipt?.lingerUnavailable;
    const logoutNote = enableLinger ? ' It stops when you sign out unless lingering can be enabled.'
      : mac || !lingering ? ' It stops when you sign out.' : '';
    const install = [];
    const notes = [];
    const add = (when, text) => { if (when) install.push(text); };
    const missing = ['git', 'npm', 'curl', 'tar'].filter((name) => !available(name));
    if (!providers.length) missing.push('at least one supported harness CLI (claude, codex, pi, or cursor)');
    if (!['darwin', 'linux'].includes(process.platform)) missing.push('a supported operating system');
    if (Number(process.versions.node.split('.')[0]) < 24) missing.push('Node.js 24 or later');
    if (mode === 'full' && !available('sudo')) missing.push('sudo');
    if (!(stage || stageQuick) && !fs.existsSync(binary)) missing.push('the bundled tightbeam-gateway binary');
    if (!mac && command('systemctl', ['--user', 'show-environment']).status !== 0) missing.push('a running systemd user manager');
    if (mac && command('launchctl', ['print', `gui/${account.uid}`]).status !== 0) missing.push('a logged-in macOS desktop session');
    if (missing.length) throw new Error(`Install the missing prerequisites and run setup again: ${missing.join(', ')}.`);
    add(stageQuick, 'Copy the verified Tightbeam package to a stable location in your home directory.');
    add(stage, 'Verify and stage the Tightbeam release under /opt/tightbeam and select it for the system service.');
    add(appArmor, 'Grant bubblewrap access to user namespaces through its AppArmor profile.');
    add(namespaceFix && !appArmor && sysctlKey, `Enable Linux user namespaces through ${sysctlKey} for the Codex sandbox.`);
    if (sandboxUnavailable && !appArmor && !sysctlKey) {
      const installBubblewrap = !bwrap ? ' An administrator also needs to install bubblewrap.' : '';
      let fix;
      if (needsAppArmor) {
        const load = 'sudo apparmor_parser -r /etc/apparmor.d/bwrap';
        const profile = shellQuote(appArmorProfile(bwrap).replaceAll('\n', '\\n'));
        fix = fs.existsSync('/etc/apparmor.d/bwrap') ? load
          : `printf '%b' ${profile} | sudo tee /etc/apparmor.d/bwrap >/dev/null && ${load}`;
      } else if (usernsLimit) {
        const value = usernsLimit === 'user.max_user_namespaces' ? 15000 : 1;
        const conf = '/etc/sysctl.d/70-tightbeam-userns.conf';
        fix = `printf '%s\\n' '${usernsLimit} = ${value}' | sudo tee ${conf} >/dev/null && sudo sysctl -p ${conf}`;
      }
      const commandNote = fix ? ` Have an administrator run: ${fix}` : '';
      notes.push(mode === 'quick'
        ? `Codex agents cannot run commands until an administrator repairs the sandbox.${installBubblewrap}${commandNote}`
        : `Disable Codex on this machine because its sandbox is unavailable.${installBubblewrap} Claude and Pi can run if configured.`);
    }
    add(upgrade, `Replace the user gateway service with a system service while keeping all data in ${base}.`);
    add(writeGateway || startGateway, mode === 'quick'
      ? `${versionChanged ? 'Restart' : 'Start'} a local-only Tightbeam user service with lighter isolation. It runs the release from your home directory and skips administrator sandbox changes.${logoutNote}`
      : `Start the Tightbeam system service under your ordinary user account, advertising ${advertisedOrigin}.`);
    add(linkCli, `Expose the Tightbeam command at ${commandLink}.`);
    add(needsPair, `Pair this computer and create the first Tightbeam administrator for ${account.username}.`);
    for (const { provider } of pending) add(true, `Set up your ${provider} credential for agent turns.`);
    for (const { provider, key } of withoutKeys) notes.push(`Skip ${provider} credential setup until you provide ${key}.`);
    add(needsMain, 'Create your main Tightbeam conversation.');
    add(installChatPackage, 'Download and verify the published Tightbeam Chat package.');
    add(enableLinger, 'Try to keep your Tightbeam user services running after sign-out with loginctl enable-linger.');
    add(writeChatMap, 'Connect local Chat over loopback and recognize the advertised gateway address as an alias.');
    add(writeChat || startChat, `Start local Tightbeam Chat as a user service.${logoutNote}`);
    add(readiness || pending.length, 'Check whether this installation can run a turn.');
    add(needsFirstRun, 'Open Tightbeam Chat and start the welcome with your Tour Guide.');
    for (const line of [...install, ...notes]) console.log(`- ${line}`);
    if (flags.dryRun || !install.length) return;
    if (!flags.yes && await ask(answers, 'Install yes or no') !== 'yes') return;
    reader.close();
    process.stdin.pause();

    if ((stage || stageQuick) && (!/^v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$/.test(tag ?? '') ||
        !/^[0-9a-f]{40}$/.test(release?.commit ?? ''))) {
      throw new Error('Setup needs the complete, verified Tightbeam release package.');
    }
    if (!receipt && (gatewayActive || fs.existsSync(gateway.file) || quickGateway.active() || fs.existsSync(quickGateway.file) ||
      chatActive || fs.existsSync(chat.file))) {
      throw new Error('A Tightbeam or Chat service already exists outside setup. Use its existing installation procedure.');
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
      if (enableLinger && command('loginctl', ['--no-ask-password', 'enable-linger', account.username]).status !== 0) {
        state.lingerUnavailable = true;
        console.error('This account could not enable lingering. Tightbeam user services stop when you sign out.');
      }
      try {
        if (appArmor) {
          const profile = '/etc/apparmor.d/bwrap';
          if (!fs.existsSync(profile)) {
            const source = path.join(scratch, 'bwrap');
            fs.writeFileSync(source, appArmorProfile(bwrap));
            run('sudo', ['apparmor_parser', '-Q', source]);
            run('sudo', ['install', '-m', '0644', source, profile]);
          }
          run('sudo', ['apparmor_parser', '-r', profile]);
        } else if (sysctlKey) {
          const value = sysctlKey === 'user.max_user_namespaces' ? '15000' : '1';
          const source = path.join(scratch, 'userns.conf');
          fs.writeFileSync(source, `${sysctlKey} = ${value}\n`);
          const conf = '/etc/sysctl.d/70-tightbeam-userns.conf';
          run('sudo', ['install', '-m', '0644', source, conf]);
          run('sudo', ['sysctl', '-p', conf]);
        }
      } catch (error) {
        console.error(`The Codex sandbox repair could not be applied: ${error.message}`);
      }
      const disableCodex = checkNamespaces && (!bwrap || !canBubblewrap());
      if (disableCodex) {
        variables.TIGHTBEAM_DISABLE_LOCAL_CODEX = 'true';
        console.error('Codex is disabled on this machine because its sandbox is unavailable.');
      }
      const usable = eligible.filter(({ provider }) => provider !== 'openai' || !sandboxUnavailable || (namespaceFix && !disableCodex));
      const replaceCodexDefault = disableCodex &&
        (!variables.TIGHTBEAM_DEFAULT_HARNESS || variables.TIGHTBEAM_DEFAULT_HARNESS === 'codex');
      if ((!variables.TIGHTBEAM_DEFAULT_HARNESS && !receipt?.main) || replaceCodexDefault) {
        const mapping = { anthropic: 'claude', openai: 'codex', cursor: 'cursor', 'opencode-go': 'pi', 'local-openai': 'pi' };
        if (usable.length || replaceCodexDefault) variables.TIGHTBEAM_DEFAULT_HARNESS = mapping[usable[0]?.provider] ?? 'claude';
        if (replaceCodexDefault && env.TIGHTBEAM_DEFAULT_HARNESS === 'codex') {
          for (const key of ['TIGHTBEAM_DEFAULT_MODEL', 'TIGHTBEAM_DEFAULT_EFFORT', 'TIGHTBEAM_DEFAULT_CONTEXT']) delete variables[key];
        }
      }
      if (stageQuick) installQuick(payload, release);
      if (stage) await stageGateway(scratch, release, () => {
        if (upgrade) {
          state.gatewayFile ??= fs.readFileSync(quickGateway.file, 'utf8');
          save();
          quickGateway.remove();
          removedQuick = true;
        }
      });
      if (writeGateway || stage || stageQuick || (mac && startGateway)) {
        gateway.install(serviceContents('gateway', mode, binary, [], variables, home), scratch, gatewayActive);
      }
      else if (startGateway) gateway.start();
      await waitFor(async () => {
        const descriptor = jsonFile(path.join(base, 'gateway.json'));
        const response = await getJson(`${localOrigin}/version`);
        return descriptor?.port === port && response?.server === 'tightbeam' && response.version === version;
      }, 'The gateway did not become ready. Check the service log and run setup again.');
      if (versionChanged) {
        state.ready = false;
      }
      Object.assign(state, {
        mode, version, advertised, tag, codexDisabled: disableCodex,
        defaultHarness: variables.TIGHTBEAM_DEFAULT_HARNESS,
      });
      save();
      removedQuick = false;

      if (linkCli) {
        selectLink(commandLink, targetCli);
        if (!(env.PATH ?? '').split(path.delimiter).includes(path.dirname(commandLink))) {
          console.log(`Add ${path.dirname(commandLink)} to PATH to run tightbeam by name.`);
        }
      }

      if (needsPair) {
        const result = await pairFirstUser(localOrigin, state.deviceId, state.admin);
        state.admin = result.userId;
        save();
        fs.writeFileSync(credentials, result.token, { flag: 'wx', mode: 0o600 });
      }
      for (const { provider, key } of pending) {
        if (!usable.some((item) => item.provider === provider)) continue;
        const onboard = ['onboard', provider, '--as-user', state.admin];
        if (provider === 'local-openai') {
          onboard.push('--name', 'local', '--endpoint', env.TIGHTBEAM_LOCAL_OPENAI_ENDPOINT);
        }
        try {
          if (env[key]) {
            run(cli, [...onboard, '--api-key'], { input: env[key], stdio: ['pipe', 'inherit', 'inherit'], cwd: home });
          } else if (provider === 'opencode-go') {
            run(cli, [...onboard, '--daemon-credential'], { cwd: home });
          } else {
            run(cli, onboard, { cwd: home });
          }
        } catch (error) {
          if (!env[key] && ['anthropic', 'openai'].includes(provider) && usable.length === 1) {
            throw new Error(`${provider} sign-in did not complete. It is the only usable harness. Sign in or configure another harness, then rerun setup.`);
          }
          console.error(`Skipped ${provider} because credential onboarding did not complete: ${error.message}`);
        }
      }
      if (installChatPackage) installChat(scratch);
      if (needsMain || needsFirstRun) {
        const auth = await gatewayFrame(localOrigin, {
          type: 'auth', deviceId: state.deviceId, token: fs.readFileSync(credentials, 'utf8'), subscriptions: ['chat'],
        }, 'auth_result').catch((error) => {
          if (needsMain) throw error;
          console.error(`Could not retry Tour Guide initialization: ${error.message}`);
          return { success: false };
        });
        if (needsMain) {
          if (!auth.success) throw new Error('Could not set up the main Tightbeam session.');
          const streams = await getJson(`${localOrigin}/api/streams`, fs.readFileSync(credentials, 'utf8'));
          state.main = streams?.streams?.find((stream) => stream.kind === 'main')?.sessionKey;
          if (!state.main) throw new Error('Could not find the main Tightbeam session.');
          save();
        }
      }
      if (writeChatMap) {
        const file = path.join(scratch, 'chat-gateways.json');
        fs.writeFileSync(file, `${JSON.stringify(chatMap, null, 2)}\n`, { mode: 0o600 });
        fs.copyFileSync(file, chatMapFile);
      }
      if (writeChat || (mac && startChat)) {
        chat.install(chatFile(state.main, state.admin), scratch, chatActive);
        state.chatOrigin = chatOrigin;
        save();
      } else if (startChat) {
        chat.start();
      }
      await waitFor(async () => {
        const target = await getJson(`${chatUrl}/chat-config.json`);
        return target?.sessionKey === state.main && target?.gateway === chatOrigin;
      }, 'Chat did not serve the installed Main conversation. Check its service log.');
      const mainLink = new URL(chatUrl);
      mainLink.search = new URLSearchParams({ gateway: chatOrigin, session: state.main });
      const credential = fs.readFileSync(credentials, 'utf8');
      const checkReadiness = () => getJson(`${localOrigin}/api/setup-readiness`, credential, 8000);
      let report = await checkReadiness();
      if (!report?.ready && usable.length) {
        try {
          await waitFor(async () => {
            report = await checkReadiness() ?? report;
            return report?.ready;
          }, 'The model catalog did not confirm turn readiness.');
        } catch (error) {
          console.error(error.message);
        }
      }
      if (state.ready !== Boolean(report?.ready)) {
        state.ready = Boolean(report?.ready);
        save();
      }
      if (report?.lines) {
        for (const line of report.lines) console.log(line);
      } else {
        console.log('NOT READY: Tightbeam could not read the gateway readiness check.');
      }
      if (state.ready && command(targetCli, ['onboard', '--first-run', '--check'], { cwd: home, env: onboardingEnv }).status === 0) {
        const welcome = command(targetCli, ['onboard', '--first-run'], {
          cwd: home, env: onboardingEnv, stdio: 'inherit',
        });
        if (welcome.status === 0) return;
      }
      console.log(`Open Main in Chat to get started with Uncle Enzo, the recommended kungfu: ${mainLink}`);
    } catch (error) {
      if (removedQuick && state.gatewayFile) {
        try {
          if (fs.existsSync(gateway.file) || gateway.active()) gateway.remove();
          quickGateway.install(state.gatewayFile, scratch, false);
        } catch (rollback) {
          throw new Error(`${error.message} The quick service could not be restored: ${rollback.message}`);
        }
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
