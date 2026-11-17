import {createPrivateKey} from 'node:crypto';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {join} from 'node:path';

import {maxEnvelopeBytes, openAppleEnvelope, sealAppleEnvelope, sha256} from './apple-envelope.mjs';

const env = process.env;
const macFiles = ['darwin-amd64-wheelmaker', 'darwin-arm64-wheelmaker'];

function jobContext(kind) {
  if (!/^[0-9a-f]{32}$/.test(env.WM_JOB_ID ?? '') || !/^v1\.[1-9]\d*$/.test(env.WM_VERSION ?? '') ||
      !/^[0-9a-f]{40}$/.test(env.WM_SOURCE_SHA ?? '')) {
    throw new Error('Apple release inputs are invalid');
  }
  const context = {kind, jobID: env.WM_JOB_ID, version: env.WM_VERSION, sourceSha: env.WM_SOURCE_SHA};
  if (kind === 'mac-result') {
    if (!/^[0-9a-f]{64}$/.test(env.WM_INPUT_SHA ?? '')) throw new Error('macOS input digest is invalid');
    context.inputSha = env.WM_INPUT_SHA;
  }
  return context;
}

async function downloadInput() {
  const context = jobContext('mac-input');
  if (!/^\d+$/.test(env.WM_ASSET_ID ?? '') || !/^[\w.-]+\/[\w.-]+$/.test(env.WM_STAGING_REPOSITORY ?? '') ||
    !/^[0-9a-f]{64}$/.test(env.WM_INPUT_SHA ?? '') || !env.WM_STAGING_TOKEN || !env.WM_MAC_INPUT_KEY) {
    throw new Error('macOS input or staging configuration is invalid');
  }
  const source = 'https://api.github.com/repos/' + env.WM_STAGING_REPOSITORY + '/releases/assets/' + env.WM_ASSET_ID;
  const headers = {
    'X-GitHub-Api-Version': '2026-03-10',
    Authorization: 'Bearer ' + env.WM_STAGING_TOKEN,
  };
  const metadataResponse = await fetch(source, {
    headers: {...headers, Accept: 'application/vnd.github+json'},
    redirect: 'error',
    signal: AbortSignal.timeout(30_000),
  });
  if (!metadataResponse.ok) throw new Error('GitHub rejected staged asset metadata');
  const metadata = await metadataResponse.json();
  if (metadata.name !== 'mac-' + env.WM_JOB_ID + '.enc' || metadata.state !== 'uploaded' ||
    !Number.isSafeInteger(metadata.size) || metadata.size < 1 || metadata.size > maxEnvelopeBytes) {
    throw new Error('Staged asset identity does not match the dispatch');
  }
  const signal = AbortSignal.timeout(5 * 60_000);
  let response = await fetch(source, {
    headers: {...headers, Accept: 'application/octet-stream'}, redirect: 'manual', signal,
  });
  if (response.status === 302) {
    const url = response.headers.get('location');
    if (!url?.startsWith('https://')) throw new Error('Staged asset download URL is invalid');
    response = await fetch(url, {signal, redirect: 'error'});
  }
  if (!response.ok || !response.body) throw new Error('GitHub rejected the staged asset download');
  let size = 0;
  const chunks = [];
  for await (const bytes of response.body) {
    size += bytes.length;
    if (size > metadata.size) throw new Error('Staged asset exceeds the declared size');
    chunks.push(bytes);
  }
  const envelope = Buffer.concat(chunks, size);
  if (size !== metadata.size || sha256(envelope) !== env.WM_INPUT_SHA) throw new Error('Staged asset digest mismatch');
  const key = createPrivateKey({key: Buffer.from(env.WM_MAC_INPUT_KEY, 'base64'), type: 'pkcs8', format: 'der'});
  const {files} = openAppleEnvelope(key, envelope, context, macFiles);
  await mkdir(env.WM_WORK, {recursive: true, mode: 0o700});
  await Promise.all(macFiles.map(name => writeFile(join(env.WM_WORK, name), files.get(name), {mode: 0o700, flag: 'wx'})));
}

async function sealResult(kind) {
  const context = jobContext(kind);
  const names = kind === 'mac-result' ? macFiles : ['WheelMaker.ipa'];
  let evidence = {};
  const files = {};
  if (env.WM_JOB_STATUS === 'success') {
    evidence = JSON.parse(await readFile(join(env.WM_WORK, 'evidence.json'), 'utf8'));
    for (const name of names) files[name] = await readFile(join(env.WM_WORK, name));
  }
  const diagnostics = await readFile(join(env.WM_WORK, 'diagnostics.log')).catch(() => Buffer.from('No diagnostics were produced.'));
  if (diagnostics.length) files['diagnostics.log'] = diagnostics;
  const encrypted = sealAppleEnvelope(env.WM_RETURN_KEY, context, files, evidence);
  await writeFile(join(env.WM_WORK, 'apple-result.enc'), encrypted, {mode: 0o600, flag: 'wx'});
}

const action = process.argv[2];
try {
  if (action === 'download-mac') await downloadInput();
  else if (action === 'seal-mac') await sealResult('mac-result');
  else if (action === 'seal-ios') await sealResult('ios-result');
  else throw new Error('Unknown Apple release operation');
} catch (error) {
  if (env.WM_WORK) {
    const {appendFile} = await import('node:fs/promises');
    await appendFile(join(env.WM_WORK, 'diagnostics.log'), String(error) + '\n', {mode: 0o600}).catch(() => {});
  }
  process.stderr.write('Apple release operation failed. See the encrypted result.\n');
  process.exitCode = 1;
}
