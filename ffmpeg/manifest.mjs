// Writes ffmpeg.json for a build of danio's FFmpeg in <dir> and signs it
// (danio's 01-ARCHITECTURE §10): which version, and each platform's file
// with its size and SHA-256. A workspace's host takes the newest release
// whose ffmpeg.json.sig checks out against the release key's public half,
// built into danio; the hashes come from here, so neither a mirror nor a
// changed download can swap the program. "kind" says it is FFmpeg's: a
// signed release.json can't pass for one, nor this for a release.json.
//
//   node manifest.mjs <dir> <version> <tag>
//
// DANIO_SIGNING_KEY: the release key (PEM), as for danio's releases.
import { createHash, createPrivateKey, sign } from 'node:crypto'
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [dir, version, tag] = process.argv.slice(2)
if (!dir || !version || !tag) {
  console.error('usage: node manifest.mjs <dir> <version> <tag>')
  process.exit(2)
}
const pem = process.env.DANIO_SIGNING_KEY
if (!pem) {
  console.error('DANIO_SIGNING_KEY is not set: an unsigned ffmpeg.json is no use to danio')
  process.exit(1)
}

const files = new RegExp(`^ffmpeg-${version.replaceAll('.', '\\.')}-((?:linux|windows)-(?:amd64|arm64))\\.tar\\.gz$`)
const assets = {}
for (const name of readdirSync(dir).sort()) {
  const m = name.match(files)
  if (!m) continue
  const body = readFileSync(join(dir, name))
  assets[name] = {
    platform: m[1],
    url: `https://github.com/Loudomian/danio-releases/releases/download/${tag}/${name}`,
    size: statSync(join(dir, name)).size,
    sha256: createHash('sha256').update(body).digest('hex'),
  }
}
const platforms = Object.values(assets).map((a) => a.platform)
for (const p of ['linux-amd64', 'linux-arm64', 'windows-amd64', 'windows-arm64']) {
  if (!platforms.includes(p)) {
    console.error(`no build for ${p} in ${dir}`)
    process.exit(1)
  }
}

const manifest = {
  kind: 'ffmpeg',
  version,
  published: new Date().toISOString(),
  source: `https://github.com/Loudomian/danio-releases/releases/download/${tag}/ffmpeg-${version}-source.tar.gz`,
  assets,
}
const body = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)
writeFileSync(join(dir, 'ffmpeg.json'), body)
writeFileSync(join(dir, 'ffmpeg.json.sig'), `${sign(null, body, createPrivateKey(pem)).toString('base64')}\n`)
console.log(`ffmpeg.json: ${platforms.length} platforms, signed`)
