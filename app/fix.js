// The on-box "fix" for the demo: add the missing index that ends the resource cascade.
// Meant to be run over SSH on the EC2 host *while the fault is live*:
//     node /opt/demoapp/fix.js        (or: ./fix.sh)
//
// Why node+pg instead of psql: the box has no psql, but it already has the pg module
// and the DB password the app uses. More importantly, it connects through the
// TRANSACTION-mode pooler on :6543 — NOT the :5432 session pool. Under the fault the
// session pool is saturated (pooler session cap), so a normal connection fails with
// "too many clients"/"too many connections". The transaction pooler has separate
// capacity, so this DDL still gets a slot while the app is on fire. That is the whole
// reason the fix "won't run" from a plain psql/5432 connection mid-incident.
const fs = require('fs');
const { Client } = require('pg');

const SECRETS = process.env.SECRETS_DIR || '/opt/demoapp/secrets';
const TARGET = process.env.SB_TARGET || 'prebaked';            // prebaked | live
const REF = process.env.SB_REF;
if (!REF) {
  throw new Error('SB_REF is required: your Supabase project ref. See .env.example');
}
const PW = (process.env.SB_PW || fs.readFileSync(`${SECRETS}/pw_${TARGET}`, 'utf8')).trim();

const client = new Client({
  host: process.env.PGHOST || 'aws-0-us-east-1.pooler.supabase.com',
  port: Number(process.env.PGPORT || 6543),   // transaction pooler
  user: `postgres.${REF}`,
  password: PW,
  database: 'postgres',
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 10000,
});

(async () => {
  console.log(`[fix] ${TARGET}: connecting via transaction pooler :6543 ...`);
  await client.connect();
  console.log('[fix] adding missing index  ->  shop.order_items(batch)');
  const t0 = Date.now();
  await client.query('create index if not exists idx_oi_batch on shop.order_items(batch)');
  console.log(`[fix] CREATE INDEX  (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
  const plan = await client.query(
    "explain select count(*), coalesce(sum(qty*price),0) from shop.order_items where batch='42'");
  const line = plan.rows.map((r) => r['QUERY PLAN']).find((l) => /Scan/.test(l)) || plan.rows[0]['QUERY PLAN'];
  console.log(`[fix] plan now: ${line.trim()}`);
  console.log('[fix] done. /report recovers to ~tens of ms; CPU + alert clear over the next few minutes.');
  await client.end();
})().catch((e) => { console.error('[fix] FAILED:', e.message); process.exit(1); });
