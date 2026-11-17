import {
  constants, createCipheriv, createDecipheriv, createHash, createPublicKey,
  privateDecrypt, publicEncrypt, randomBytes,
} from 'node:crypto';

const magic = Buffer.from('WMA1');
const wrappedKeySize = 384;
const nonceSize = 12;
const tagSize = 16;
const headerSize = magic.length + wrappedKeySize + nonceSize + tagSize;
const maxManifestBytes = 64 * 1024;
export const maxEnvelopeBytes = 512 * 1024 * 1024;

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function readApplePublicKey(value) {
  const key = typeof value === 'string'
    ? createPublicKey({key: Buffer.from(value, 'base64'), format: 'der', type: 'spki'})
    : value;
  if (key?.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength !== 3072) {
    throw new Error('Apple release encryption requires a 3072-bit RSA public key');
  }
  return key;
}

export function sealAppleEnvelope(publicKey, context, files, evidence = {}) {
  const entries = Object.entries(files);
  const manifest = Buffer.from(JSON.stringify({
    schema: 1,
    context,
    evidence,
    files: entries.map(([name, body]) => ({name, size: body.length, sha256: sha256(body)})),
  }));
  const manifestLength = Buffer.alloc(4);
  manifestLength.writeUInt32BE(manifest.length);
  const bodies = entries.map(([, body]) => body);
  if (manifest.length > maxManifestBytes ||
    bodies.reduce((length, body) => length + body.length, headerSize + 4 + manifest.length) > maxEnvelopeBytes) {
    throw new Error('Apple release payload exceeds the size limit');
  }
  const key = randomBytes(32);
  const nonce = randomBytes(nonceSize);
  const wrappedKey = publicEncrypt({
    key: readApplePublicKey(publicKey), padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256',
  }, key);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(magic);
  const encrypted = [manifestLength, manifest, ...bodies].map(part => cipher.update(part));
  encrypted.push(cipher.final());
  return Buffer.concat([magic, wrappedKey, nonce, cipher.getAuthTag(), ...encrypted]);
}

export function openAppleEnvelope(privateKey, envelope, expectedContext, names, optionalNames = []) {
  if (envelope.length <= headerSize || envelope.length > maxEnvelopeBytes ||
    !envelope.subarray(0, magic.length).equals(magic)) {
    throw new Error('Apple release envelope has an invalid header or size');
  }
  const wrappedKeyEnd = magic.length + wrappedKeySize;
  const nonceEnd = wrappedKeyEnd + nonceSize;
  let plain;
  try {
    const key = privateDecrypt({
      key: privateKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256',
    }, envelope.subarray(magic.length, wrappedKeyEnd));
    const decipher = createDecipheriv('aes-256-gcm', key, envelope.subarray(wrappedKeyEnd, nonceEnd));
    decipher.setAAD(magic);
    decipher.setAuthTag(envelope.subarray(nonceEnd, headerSize));
    plain = decipher.update(envelope.subarray(headerSize));
    decipher.final();
  } catch {
    throw new Error('Apple release envelope failed authentication');
  }
  const manifestLength = plain.length >= 4 ? plain.readUInt32BE() : 0;
  let cursor = 4 + manifestLength;
  if (!manifestLength || manifestLength > maxManifestBytes || cursor > plain.length) {
    throw new Error('Apple release envelope has an invalid manifest size');
  }
  let manifest;
  try {
    manifest = JSON.parse(plain.subarray(4, cursor));
  } catch {
    throw new Error('Apple release envelope has an invalid manifest');
  }
  if (manifest?.schema !== 1 || !Array.isArray(manifest.files) || !manifest.context ||
    Object.keys(manifest.context).length !== Object.keys(expectedContext).length ||
    !Object.entries(expectedContext).every(([key, value]) => manifest.context[key] === value)) {
    throw new Error('Apple release result identity does not match the requested job');
  }

  const allowed = new Set([...names, ...optionalNames]);
  const files = new Map();
  for (const file of manifest.files) {
    const {name, size, sha256: digest} = file ?? {};
    if (!allowed.has(name) || files.has(name) || !Number.isSafeInteger(size) || size <= 0 || size > plain.length - cursor) {
      throw new Error('Apple release result contains an unexpected or invalid file');
    }
    const content = plain.subarray(cursor, cursor + size);
    if (sha256(content) !== digest) throw new Error('Apple release file SHA-256 mismatch');
    files.set(name, content);
    cursor += size;
  }
  if (cursor !== plain.length || names.some(name => !files.has(name))) {
    throw new Error('Apple release result is missing required files');
  }
  return {files, evidence: manifest.evidence};
}
