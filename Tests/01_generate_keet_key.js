#!/usr/bin/env node
'use strict'

const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const { createInvite, decodeInvite } = require('blind-pairing-core')
const { encode: encodeCoreKey, decode: decodeCoreKey } = require('hypercore-id-encoding')

function printHelp() {
  console.log(`Keet Test 01 - Generate and validate Keet key material

Usage:
  node ./Tests/01_generate_keet_key.js [--key <hex|base64>] [--out <file>]

Options:
  --key <value>   Optional existing 32-byte key in hex (64 chars) or base64.
  --out <file>    Optional output JSON file path.
  --help          Show this help.
`)
}

function parseArgs(argv) {
  const cfg = { key: null, out: null, help: false }
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]
    if (token === '--key' && i + 1 < argv.length) {
      cfg.key = argv[++i]
      continue
    }
    if (token === '--out' && i + 1 < argv.length) {
      cfg.out = argv[++i]
      continue
    }
    if (token === '--help' || token === '-h') {
      cfg.help = true
      continue
    }
    throw new Error('Unknown argument: ' + token)
  }
  return cfg
}

function parseKey(raw) {
  const value = String(raw || '').trim()
  if (!value) throw new Error('Missing key value')

  if (/^[0-9a-fA-F]{64}$/.test(value)) {
    return Buffer.from(value, 'hex')
  }

  const b64 = Buffer.from(value, 'base64')
  if (b64.byteLength === 32) return b64

  throw new Error('Invalid key format. Use 32-byte hex (64 chars) or base64.')
}

function main() {
  const cfg = parseArgs(process.argv.slice(2))
  if (cfg.help) {
    printHelp()
    return
  }

  const key = cfg.key ? parseKey(cfg.key) : crypto.randomBytes(32)
  const keySource = cfg.key ? 'provided' : 'generated'

  const { invite } = createInvite(key)
  const decoded = decodeInvite(invite)
  if (!decoded.discoveryKey || decoded.discoveryKey.byteLength !== 32) {
    throw new Error('Key validation failed: discoveryKey is invalid')
  }

  const roomId = encodeCoreKey(decoded.discoveryKey)
  const roundtrip = decodeCoreKey(roomId)
  if (!Buffer.from(roundtrip).equals(Buffer.from(decoded.discoveryKey))) {
    throw new Error('Key validation failed: roomId encode/decode mismatch')
  }

  const output = {
    ok: true,
    keySource,
    keyHex: key.toString('hex'),
    keyBase64: key.toString('base64'),
    discoveryKeyHex: Buffer.from(decoded.discoveryKey).toString('hex'),
    roomId,
    inviteUrl: `pear://keet/${roomId}`,
    checks: [
      'createInvite(key) succeeded',
      'decodeInvite(invite).discoveryKey is 32 bytes',
      'hypercore-id-encoding encode/decode roundtrip succeeded'
    ]
  }

  const json = JSON.stringify(output, null, 2)
  console.log(json)

  if (cfg.out) {
    const target = path.resolve(cfg.out)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.writeFileSync(target, json + '\n', { mode: 0o600 })
    fs.chmodSync(target, 0o600)
    console.error('[saved] ' + target)
  }
}

try {
  main()
} catch (err) {
  console.error(err && err.message ? err.message : String(err))
  process.exit(1)
}
