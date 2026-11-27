import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { archives, releaseIdentity, releaseUrl } from './npm/release.mjs';

const [tag, checksumFile, output] = process.argv.slice(2);
const { version, build, npmVersion } = releaseIdentity(tag);
const platforms = archives(tag, await readFile(checksumFile, 'utf8'));

function resource(name, platform) {
  const { name: archive, sha256 } = platforms[platform];
  return [
    '  on_' + name + ' do',
    '    url "' + releaseUrl(tag, archive) + '"',
    '    sha256 "' + sha256 + '"',
    '  end',
  ].join('\n');
}

const formula = `class Tightbeam < Formula
  desc "Run and coordinate AI agents"
  homepage "https://github.com/clickety-clacks/tightbeam"
  version "${version}"
  revision ${build}

  depends_on arch: :arm64 if OS.mac?
  depends_on arch: :x86_64 if OS.linux?
  depends_on "node"

${resource('macos', 'darwin-arm64')}

${resource('linux', 'linux-x64')}

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/tightbeam"
  end

  def caveats
    "Run tightbeam setup to configure Tightbeam."
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/tightbeam --version")
  end
end
`;

const npmOutput = join(output, 'npm');
await mkdir(npmOutput, { recursive: true });
for (const file of ['release.mjs', 'install.mjs', 'README.md']) {
  await copyFile(new URL('./npm/' + file, import.meta.url), join(npmOutput, file));
}
const manifest = JSON.parse(await readFile(new URL('./npm/package.json', import.meta.url), 'utf8'));
manifest.version = npmVersion;
manifest.tightbeamRelease = tag;
await writeFile(join(npmOutput, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
await writeFile(join(output, 'tightbeam.rb'), formula);
