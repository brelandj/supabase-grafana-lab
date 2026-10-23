// Demo app for the Supabase <-> Grafana enablement demo.
// Exposes Prometheus metrics at /metrics. The /report endpoint (aliased as
// /recommendations) runs the intentionally un-indexed query, so ramping traffic to it
// drives the DB resource cascade *through the app* — app latency/errors and the Supabase
// DB panels move together, which is the whole-stack story Supabase can't show.
const fs = require('fs');
const express = require('express');
const client = require('prom-client');
const { Pool } = require('pg');

const PORT = Number(process.env.PORT || 8080);
const SECRETS = process.env.SECRETS_DIR || './secrets';
const TARGET = process.env.SB_TARGET || 'prebaked';           // prebaked | live
const REF = process.env.SB_REF;
if (!REF) {
  throw new Error('SB_REF is required: your Supabase project ref. See .env.example');
}
const PW = (process.env.SB_PW || fs.readFileSync(`${SECRETS}/pw_${TARGET}`, 'utf8')).trim();

const pool = new Pool({
  host: process.env.PGHOST || 'aws-0-us-east-1.pooler.supabase.com',
  port: Number(process.env.PGPORT || 5432),
  user: `postgres.${REF}`,
  password: PW,
  database: 'postgres',
  max: Number(process.env.PG_POOL_MAX || 12),   // stays under the pooler's 15 session cap
  idleTimeoutMillis: 10000,
  connectionTimeoutMillis: 8000,
  // queries slower than this get cancelled -> the handler returns 500, so the fault
  // shows a real 5xx spike (recovers to 0 once the index makes queries fast).
  statement_timeout: Number(process.env.STMT_TIMEOUT_MS || 3000),
  query_timeout: Number(process.env.STMT_TIMEOUT_MS || 3000),
  ssl: { rejectUnauthorized: false },
});
pool.on('error', () => {});  // don't crash on idle client errors

// ---- metrics ----
client.collectDefaultMetrics();
const httpDur = new client.Histogram({
  name: 'demoapp_http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5, 10],
});
const httpTotal = new client.Counter({
  name: 'demoapp_http_requests_total', help: 'HTTP requests', labelNames: ['method', 'route', 'status'],
});
const httpErrors = new client.Counter({
  name: 'demoapp_http_errors_total', help: 'HTTP 5xx responses', labelNames: ['route'],
});
const inflight = new client.Gauge({ name: 'demoapp_http_inflight', help: 'in-flight requests' });

// A labelled counter does not exist until it is first incremented, so an error-free app
// publishes NO demoapp_http_errors_total series at all and the error-rate panel renders
// empty instead of a flat zero line. On a dashboard that reads as "no data" (broken or
// not wired up) rather than "zero errors". Seed the demo's routes at 0 so the panel shows
// a real baseline that the fault's 5xx spike then rises from. Only the routes actually
// driven are seeded, to keep the legend free of permanently-flat series.
const INIT_ERROR_ROUTES = (process.env.INIT_ERROR_ROUTES || '/report,/order')
  .split(',').map((s) => s.trim()).filter(Boolean);
INIT_ERROR_ROUTES.forEach((route) => httpErrors.inc({ route }, 0));

// ---- structured logs (stdout -> journal -> Loki) ----
// Baseline load runs ~60 rps on /order, so logging every request would bury the
// fault signal in noise and burn log quota. 5xx and slow requests are always
// emitted; healthy ones are sampled just often enough to prove the pipeline works.
const LOG_SAMPLE_N = Number(process.env.LOG_SAMPLE_N || 50);
const LOG_SLOW_MS = Number(process.env.LOG_SLOW_MS || 1000);
let sampleSeq = 0;

function log(level, msg, fields) {
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields }) + '\n');
}

const app = express();
app.use((req, res, next) => {
  const route = req.path;
  const end = httpDur.startTimer({ method: req.method, route });
  const startedAt = process.hrtime.bigint();
  inflight.inc();
  // Settle on BOTH finish and close, guarded to run once. 'finish' alone leaks the
  // in-flight gauge: under the fault the load generator destroys sockets that are past
  // its timeout, those responses never emit 'finish', and the gauge ratchets up for the
  // life of the process (it read ~200 at idle, which makes the panel meaningless).
  let settled = false;
  const settle = () => {
    if (settled) return;
    settled = true;
    const labels = { method: req.method, route, status: res.statusCode };
    end({ status: res.statusCode });
    httpTotal.inc(labels);
    if (res.statusCode >= 500) httpErrors.inc({ route });
    inflight.dec();

    if (route === '/metrics' || route === '/healthz') return;
    const durationMs = Number((process.hrtime.bigint() - startedAt) / 1000000n);
    const base = { method: req.method, route, status: res.statusCode, duration_ms: durationMs };
    const err = res.locals.dbError;
    if (res.statusCode >= 500) {
      log('error', 'request failed', { ...base, ...err });
    } else if (durationMs >= LOG_SLOW_MS) {
      log('warn', 'slow request', { ...base, ...err });
    } else if (++sampleSeq % LOG_SAMPLE_N === 0) {
      log('info', 'request ok', base);
    }
  };
  res.on('finish', settle);
  res.on('close', settle);
  next();
});

// the expensive, un-indexed report (drives the cascade)
// selective (~1/1000) filter on the large UN-indexed order_items.batch column:
// un-indexed -> full 1.25M seq scan (the cascade); index on batch -> ~1250 rows (recovery).
const REPORT_SQL = `select count(*) as n, coalesce(sum(qty*price),0) as revenue
  from shop.order_items where batch = $1`;

// Two names for each endpoint, one handler behind them. The run of show is scripted
// against /report and /order — it quotes per-route latency and throughput numbers — but
// /recommendations and /play are kept as aliases so you can re-skin the demo for a
// different narrative without a second deployment. The metrics `route` label comes from
// req.path, so each alias produces its own series and the dashboards still line up.
const EXPENSIVE_PATHS = ['/report', '/recommendations'];
const HEALTHY_PATHS = ['/order', '/play'];

// The scan takes ~1.7s unloaded against the pool's 3s statement_timeout, so app-driven
// load alone does not reliably trip it: extra latency comes from waiting for a pooled
// connection, and statement_timeout does not count queue time. The result is requests
// that are very slow but return 200, which gives an investigating agent no cause to
// name. Routes listed here get a tighter per-transaction timeout so the query is
// genuinely cancelled and pg returns 57014.
//
// Applied per-path rather than globally on purpose: /report keeps the 3s ceiling the
// run of show quotes, while /recommendations gets the tighter timeout so it fails
// deterministically if you want a cleaner error-rate story. Pool contention is
// unchanged either way, so the blast-radius story on the healthy route survives.
const TIGHT_TIMEOUT_MS = Number(process.env.TIGHT_TIMEOUT_MS || 1200);
const TIGHT_TIMEOUT_PATHS = new Set(
  (process.env.TIGHT_TIMEOUT_PATHS || '/recommendations').split(',').map((s) => s.trim()),
);

async function expensiveHandler(req, res) {
  const tight = TIGHT_TIMEOUT_PATHS.has(req.path);
  try {
    let r;
    if (tight) {
      const client = await pool.connect();
      try {
        // SET LOCAL is transaction-scoped, so the shortened timeout cannot leak onto the
        // next request that borrows this pooled connection.
        await client.query('begin');
        await client.query(`set local statement_timeout = ${TIGHT_TIMEOUT_MS}`);
        r = await client.query(REPORT_SQL, ['42']);
        await client.query('commit');
      } catch (inner) {
        await client.query('rollback').catch(() => {});
        throw inner;
      } finally {
        client.release();
      }
    } else {
      r = await pool.query(REPORT_SQL, ['42']);
    }
    res.json({ ok: true, rows: r.rows });
  } catch (e) {
    // pg surfaces a statement timeout as code 57014 ("canceling statement due to
    // statement timeout") — the signal that identifies this as a slow query, not
    // a connectivity or application fault.
    res.locals.dbError = { query: 'report_revenue_by_batch', db_error: e.message, pg_code: e.code };
    res.status(500).json({ ok: false, error: e.message });
  }
}

// a healthy, indexed endpoint for baseline contrast
async function healthyHandler(req, res) {
  try {
    const id = 1 + Math.floor(Math.random() * 20000);
    const r = await pool.query(
      'select id, total, status from shop.orders where customer_id = $1 order by created_at desc limit 20', [id]);
    res.json({ ok: true, count: r.rowCount });
  } catch (e) {
    res.locals.dbError = { query: 'orders_by_customer', db_error: e.message, pg_code: e.code };
    res.status(500).json({ ok: false, error: e.message });
  }
}

app.get(EXPENSIVE_PATHS, expensiveHandler);
app.get(HEALTHY_PATHS, healthyHandler);

app.get('/healthz', (_req, res) => res.json({ ok: true }));
app.get('/', (_req, res) => res.json({
  app: 'supabase-grafana-demo',
  target: TARGET,
  endpoints: [...EXPENSIVE_PATHS, ...HEALTHY_PATHS, '/metrics', '/healthz'],
}));
app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

app.listen(PORT, () => log('info', 'demo app listening', { port: PORT, target: TARGET, ref: REF }));
