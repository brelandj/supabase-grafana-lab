// fixd: holds ONE dedicated DB connection open for the life of the demo so the fix can
// always be applied — even when the cascade has consumed every connection slot.
//
// Why this exists: the project's max_connections is 60 (57 usable after superuser
// reserves). At peak the fault's backends fill that ceiling, so *opening a new
// connection to run the fix fails* with "remaining connection slots are reserved for
// roles with the SUPERUSER attribute" / 53300 "too many clients already". Retrying does
// not help: the slot never frees while the fault runs. The only reliable answer is to
// already hold a connection before the incident starts, and run the DDL over it.
//
// Connects on port 5432 (SESSION mode) on purpose: session mode pins one dedicated
// backend for the life of the client connection, which is exactly the reservation we
// want. Transaction mode (6543) hands back a backend per transaction, so at fix time it
// would still need a free one — defeating the point.
//
// Start this at ARM time (before any load), then trigger it during the incident:
//   curl -s localhost:8081/fix     -> create the missing index  (THE FIX)
//   curl -s localhost:8081/unfix   -> drop it again (re-arm between takes)
//   curl -s localhost:8081/status  -> is the connection held? is the index present?
const fs = require('fs');
const http = require('http');
const { Client } = require('pg');

const PORT = Number(process.env.FIXD_PORT || 8081);
const SECRETS = process.env.SECRETS_DIR || '/opt/demoapp/secrets';
const TARGET = process.env.SB_TARGET || 'prebaked';
const REF = process.env.SB_REF;
if (!REF) {
  throw new Error('SB_REF is required: your Supabase project ref. See .env.example');
}
const PW = (process.env.SB_PW || fs.readFileSync(`${SECRETS}/pw_${TARGET}`, 'utf8')).trim();

const INDEX_SQL = 'create index if not exists idx_oi_batch on shop.order_items(batch)';
const DROP_SQL = 'drop index if exists shop.idx_oi_batch';
const PLAN_SQL = "explain select count(*), coalesce(sum(qty*price),0) from shop.order_items where batch='42'";

let client = null;
let connectedAt = null;

function log(...a) { console.log(new Date().toISOString(), ...a); }

async function connect() {
  const c = new Client({
    host: process.env.PGHOST || 'aws-0-us-east-1.pooler.supabase.com',
    port: Number(process.env.PGPORT || 5432),   // session mode: pins a dedicated backend
    user: `postgres.${REF}`,
    password: PW,
    database: 'postgres',
    ssl: { rejectUnauthorized: false },
    connectionTimeoutMillis: 15000,
    application_name: 'demo-fixd',
  });
  c.on('error', (e) => { log('held connection error:', e.message); client = null; });
  await c.connect();
  // CREATE INDEX on 1.25M rows takes ~10s idle and longer under load. The app sets a 3s
  // statement_timeout for its own pool; this connection must never inherit that kind of
  // cap or the fix would be cancelled mid-build.
  await c.query('set statement_timeout = 0');
  await c.query('set idle_in_transaction_session_timeout = 0');
  client = c;
  connectedAt = new Date();
  log(`holding dedicated connection to ${TARGET} (:5432 session mode)`);
}

// Keepalive: prove the reservation is still alive, and re-take it if it ever drops.
// Reconnecting may fail while the fault is saturating the DB — that is precisely why we
// grab the slot at arm time instead of at fix time.
setInterval(async () => {
  try {
    if (client) await client.query('select 1');
    else await connect();
  } catch (e) { log('keepalive failed:', e.message); client = null; }
}, 20000);

async function held(sql) {
  if (!client) throw new Error('no held connection (fixd lost its slot) — start fixd before the fault');
  return client.query(sql);
}

const routes = {
  '/fix': async () => {
    const t0 = Date.now();
    await held(INDEX_SQL);
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    const plan = await held(PLAN_SQL);
    const line = plan.rows.map((r) => r['QUERY PLAN']).find((l) => /Scan/.test(l)) || '';
    return `[fix] CREATE INDEX on shop.order_items(batch) in ${secs}s\n`
         + `[fix] plan now: ${line.trim()}\n`
         + '[fix] done — /report recovers to ~tens of ms; CPU + alert clear shortly\n';
  },
  '/unfix': async () => {
    await held(DROP_SQL);
    const plan = await held(PLAN_SQL);
    const line = plan.rows.map((r) => r['QUERY PLAN']).find((l) => /Scan/.test(l)) || '';
    return `[unfix] index dropped -> fault hook re-armed\n[unfix] plan now: ${line.trim()}\n`;
  },
  '/status': async () => {
    const idx = await held(
      "select coalesce(string_agg(indexname,','),'none') i from pg_indexes "
      + "where schemaname='shop' and tablename='order_items' and indexname='idx_oi_batch'");
    const conns = await held(
      'select count(*) total, count(*) filter (where state=\'active\') active from pg_stat_activity');
    return `held=yes since=${connectedAt && connectedAt.toISOString()} target=${TARGET}\n`
         + `fault_index=${idx.rows[0].i}\n`
         + `db_connections total=${conns.rows[0].total} active=${conns.rows[0].active}\n`;
  },
};

http.createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  const fn = routes[path];
  if (!fn) { res.writeHead(404).end('routes: /fix /unfix /status\n'); return; }
  try {
    const body = await fn();
    log(`${path} ok`);
    res.writeHead(200, { 'Content-Type': 'text/plain' }).end(body);
  } catch (e) {
    log(`${path} FAILED: ${e.message}`);
    res.writeHead(500, { 'Content-Type': 'text/plain' }).end(`[fixd] FAILED: ${e.message}\n`);
  }
}).listen(PORT, '127.0.0.1', () => log(`fixd listening on 127.0.0.1:${PORT}`));

connect().catch((e) => log('initial connect failed:', e.message));
