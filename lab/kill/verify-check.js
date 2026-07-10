#!/usr/bin/env node
// Standalone Ed25519 kill-command verifier - hand-verification gate.
// NO Electron, NO runtime deps - only Node built-in crypto.
//
// Usage:
//   node lab/kill/verify-check.js <signed-kill-command.json>
//
// Exits 0 on VALID, 1 on INVALID.
// Verifies a signed kill-command document: sequential checks below, with the signature checked
// FIRST so forged or tampered fields are never acted on, even for logging.
'use strict'

const { verify } = require('crypto')
const { readFileSync } = require('fs')
const { resolve, join } = require('path')

const scriptDir = __dirname
const pubKeyPath = join(scriptDir, 'kill-signing.pub')
const docPath = process.argv[2]

if (!docPath) {
  console.error('Usage: node verify-check.js <signed-kill-command.json>')
  process.exit(1)
}

function reject(reason) {
  console.log(`INVALID - ${reason}`)
  process.exit(1)
}

// --- Load public key ---
let publicKeyPem
try {
  publicKeyPem = readFileSync(pubKeyPath, 'utf8')
} catch (e) {
  console.error(`Cannot read public key at ${pubKeyPath}: ${e.message}`)
  process.exit(1)
}

// --- Load document ---
let doc
try {
  doc = JSON.parse(readFileSync(resolve(docPath), 'utf8'))
} catch (e) {
  reject(`parse error - ${e.message}`)
}

// Step 1: required fields
const REQUIRED = ['action', 'command_id', 'device_id', 'issued_at', 'signature']
for (const f of REQUIRED) {
  if (doc[f] === undefined) reject(`missing field: ${f}`)
}

const { action, command_id, device_id, issued_at, signature } = doc

// Step 2: type checks
if (typeof action      !== 'string')  reject('action must be a string')
if (typeof command_id  !== 'string')  reject('command_id must be a string')
if (typeof device_id   !== 'string')  reject('device_id must be a string')
if (!Number.isInteger(issued_at))     reject('issued_at must be an integer (epoch ms)')
if (typeof signature   !== 'string')  reject('signature must be a string')

// Step 3: reconstruct canonical bytes
// Keys in ascending alphabetical order: action < command_id < device_id < issued_at
const canonical = JSON.stringify({ action, command_id, device_id, issued_at })
const canonicalBytes = Buffer.from(canonical, 'utf8')

// Step 4: decode signature
let sigBytes
try {
  sigBytes = Buffer.from(signature, 'base64')
} catch (e) {
  reject('signature is not valid base64')
}
if (sigBytes.length !== 64) reject(`signature wrong length: expected 64 bytes, got ${sigBytes.length}`)

// Step 5: Ed25519 verify (algorithm=null = no pre-hash, pure EdDSA)
let sigValid
try {
  sigValid = verify(null, canonicalBytes, publicKeyPem, sigBytes)
} catch (e) {
  reject(`crypto.verify threw: ${e.message}`)
}
if (!sigValid) reject('bad signature')

// Step 6: device_id check (prints the expected device so user can spot mismatches)
// In this standalone verifier we accept any device_id (no "this device" concept outside Electron).
// We log it so the user can confirm it matches.
console.log(`device_id   : ${device_id}`)
console.log(`command_id  : ${command_id}`)
console.log(`action      : ${action}`)
console.log(`issued_at   : ${issued_at} (${new Date(issued_at).toISOString()})`)
console.log(`canonical   : ${canonical}`)
console.log()
console.log('VALID - Ed25519 signature verified against lab/kill/kill-signing.pub')
process.exit(0)
