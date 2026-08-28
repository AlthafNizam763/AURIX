/**
 * Works out why `mongodb+srv://` cannot resolve.
 *
 *   npm run check-dns
 *
 * ## Why this script exists
 *
 * `querySrv ECONNREFUSED` is reported by the MongoDB driver, so it reads like a
 * database problem. It is not: it happens before a single byte reaches Atlas.
 *
 * An `mongodb+srv://` URI is not an address — it is an instruction to look up a
 * **DNS SRV record** and a **TXT record**, and to connect to whatever hosts
 * those name. That lookup uses `dns.resolveSrv`, which talks to a DNS server
 * directly on port 53 rather than going through the operating system's
 * resolver. Plenty of networks break that specific path while ordinary browsing
 * works perfectly: corporate DNS that answers A records and refuses SRV, a VPN
 * that captures port 53, a router whose resolver rejects anything unusual, or
 * security software sitting in front of the stack.
 *
 * So this walks the layers from the bottom and reports the first one that
 * fails, which is the one to fix.
 */
import dns from 'node:dns';
import dnsPromises from 'node:dns/promises';

import { env } from '../src/config/env.js';

const SRV_PREFIX = '_mongodb._tcp.';

/** The cluster hostname out of the URI, without touching the credentials. */
function clusterHost() {
  const match = /^mongodb\+srv:\/\/[^@]*@([^/?]+)/.exec(env.mongoUri);
  if (match) return { host: match[1], srv: true };

  const plain = /^mongodb:\/\/[^@]*@([^/?,]+)/.exec(env.mongoUri);
  if (plain) return { host: plain[1].split(':')[0], srv: false };

  return null;
}

const line = (ok, label, detail) =>
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label.padEnd(38)} ${detail ?? ''}`);

async function tryStep(label, run) {
  try {
    const detail = await run();
    line(true, label, detail);
    return true;
  } catch (error) {
    line(false, label, `${error.code ?? ''} ${error.message}`.trim());
    return false;
  }
}

const target = clusterHost();
if (!target) {
  console.error('Could not read a cluster hostname out of MONGODB_URI.');
  process.exit(1);
}

console.log(`\nChecking DNS for ${target.host}\n`);
console.log(`Resolvers in use: ${dns.getServers().join(', ') || '(none configured)'}\n`);

// 1. The OS resolver. This is what a browser uses, so it almost always works —
//    and it is deliberately not what the MongoDB driver uses for SRV.
const osLookup = await tryStep('OS resolver (dns.lookup)', async () => {
  const { address } = await dnsPromises.lookup('mongodb.com');
  return `mongodb.com → ${address}`;
});

// 2. Direct DNS on port 53, still an ordinary A record. If this fails, nothing
//    that follows can work and the problem is the network, not MongoDB.
const directA = await tryStep('Direct DNS, A record', async () => {
  const [address] = await dnsPromises.resolve4('mongodb.com');
  return `mongodb.com → ${address}`;
});

// 3. The lookup the driver actually performs.
const srv = await tryStep(`Direct DNS, SRV record`, async () => {
  const records = await dnsPromises.resolveSrv(SRV_PREFIX + target.host);
  return `${records.length} shard(s): ${records.map((r) => r.name).join(', ')}`;
});

// 4. The same SRV lookup against a public resolver. If this succeeds where the
//    default failed, the fix is one line of configuration — see below.
let publicWorks = false;
if (!srv) {
  const original = dns.getServers();
  dns.setServers(['1.1.1.1', '8.8.8.8']);
  publicWorks = await tryStep('SRV via 1.1.1.1 / 8.8.8.8', async () => {
    const records = await dnsPromises.resolveSrv(SRV_PREFIX + target.host);
    return `${records.length} shard(s) — the default resolver is the problem`;
  });
  dns.setServers(original);
}

console.log();

if (!osLookup && !directA) {
  console.log('No DNS is resolving at all. This machine has no working network,');
  console.log('or something is intercepting it. Nothing below will help until');
  console.log('that is fixed.');
} else if (!srv && publicWorks) {
  console.log('Your default DNS resolver answers A records but refuses SRV.');
  console.log('That is what breaks mongodb+srv:// specifically.');
  console.log();
  console.log('Fix it either way:');
  console.log();
  console.log('  A. Add this to server/.env — the API will use these resolvers');
  console.log('     for the SRV lookup and nothing else:');
  console.log();
  console.log('       DNS_SERVERS=1.1.1.1,8.8.8.8');
  console.log();
  console.log('  B. Or switch to the non-SRV connection string, which needs no');
  console.log('     SRV lookup at all. In Atlas: Connect → Drivers → change the');
  console.log('     driver version to "Node.js 2.2.12 or later". You get a');
  console.log('     mongodb:// URI listing the shards directly.');
} else if (!srv) {
  console.log('The SRV lookup fails even against public DNS. Port 53 is likely');
  console.log('blocked outbound, or a VPN / security product is intercepting');
  console.log('DNS. Use the non-SRV connection string:');
  console.log();
  console.log('  Atlas → Connect → Drivers → driver version "Node.js 2.2.12 or');
  console.log('  later" → copy the mongodb:// URI into MONGODB_URI.');
  console.log();
  console.log('If that also fails to connect, outbound 27017 is blocked too and');
  console.log('the network itself has to be changed.');
} else {
  console.log('DNS is fine. If `npm start` still fails, the next suspects are:');
  console.log();
  console.log('  * Atlas → Network Access: add your current IP to the allowlist.');
  console.log('    Symptom is an ~8s hang then a server-selection timeout.');
  console.log('  * Atlas → Database Access: wrong username or password.');
  console.log('    Symptom is an immediate authentication failure.');
  console.log('  * Outbound TCP 27017 blocked by a firewall.');
}

console.log();
