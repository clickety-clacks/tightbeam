export const repository = 'clickety-clacks/tightbeam';
export const platforms = {
  'darwin-arm64': 'darwin-aarch64',
  'linux-x64': 'linux-x86_64',
};

export function releaseIdentity(tag) {
  const match = /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+([1-9]\d*)$/.exec(tag);
  if (!match) throw new Error('Invalid release tag: ' + tag);
  const [, version, build] = match;
  return { version, build, npmVersion: version + '-build.' + build };
}

export function archives(tag, checksums) {
  const { version } = releaseIdentity(tag);
  const entries = checksums.trim().split(/\r?\n/);
  return Object.fromEntries(Object.entries(platforms).map(([key, platform]) => {
    const prefix = ['tightbeam', version.replaceAll('.', '\\.'), platform].join('-');
    const pattern = new RegExp('^([a-f0-9]{64}) [ *](' + prefix + '-[a-f0-9]{7}\\.tgz)$');
    const matches = entries.map(line => pattern.exec(line)).filter(Boolean);
    if (matches.length !== 1) throw new Error('Expected one SHA256SUMS entry for ' + platform);
    const [, sha256, name] = matches[0];
    return [key, { name, sha256 }];
  }));
}

export function releaseUrl(tag, name) {
  return 'https://github.com/' + repository + '/releases/download/' + encodeURIComponent(tag) + '/' + name;
}
