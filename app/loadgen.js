// Simple HTTP load generator for the demo app.
//   RATE=20 PATHS=/order   node loadgen.js     # baseline (healthy, indexed)
//   RATE=30 PATHS=/report  node loadgen.js     # fault (drives the cascade through the app)
//   CONC=12 PATHS=/report  node loadgen.js     # legacy closed-loop mode (see below)
//
// RATE (open loop) vs CONC (closed loop) — this choice decides whether the demo can show
// recovery on DB CPU at all:
//
//   CONC workers each loop `await hit()`, so offered throughput is inversely proportional
//   to latency. Before the index, /report takes ~4s and 20 workers manage ~7 rps; after
//   the index it takes ~50ms and the SAME workers push ~720 rps. Each query got ~90x
//   cheaper but ~95x more numerous, so total DB CPU stays pegged and the Supabase CPU
//   panel shows no recovery — the fix looks like it did nothing.
//
//   RATE offers a CONSTANT request rate regardless of latency, which is how real traffic
//   behaves (users don't speed up because your DB got faster). Fixed offered load means
//   the per-query cost drop shows up directly as a CPU drop: saturated seq scans before,
//   trivial index lookups after. Prefer RATE for the demo.
const http = require('http');
const BASE = process.env.APP_URL || 'http://localhost:8080';
const PATHS = (process.env.PATHS || '/report').split(',');
const CONC = Number(process.env.CONC || 10);
const RATE = Number(process.env.RATE || 0);              // req/s; >0 enables open loop
// Under the fault, requests last until the pool's 8s connection timeout, so in-flight
// settles around RATE*8. The cap only guards against unbounded socket growth if the app
// stops responding entirely.
const MAX_INFLIGHT = Number(process.env.MAX_INFLIGHT || 600);

function hit() {
  return new Promise((resolve) => {
    const p = PATHS[Math.floor(Math.random() * PATHS.length)];
    const req = http.get(BASE + p, (res) => { res.resume(); res.on('end', resolve); });
    req.on('error', () => resolve());
    req.setTimeout(15000, () => { req.destroy(); resolve(); });
  });
}
async function worker() { for (;;) { await hit(); } }

if (RATE > 0) {
  // Dispatch on a fixed 20ms tick, accumulating fractional credit so any rate works
  // (RATE=30 -> 0.6 requests per tick). Credit is capped at one second's worth so a
  // stalled app cannot build an unbounded backlog that all fires at once on recovery.
  const PERIOD_MS = 20;
  let inflight = 0;
  let credit = 0;
  console.log(`loadgen: ${RATE} req/s (open loop) -> ${BASE} ${JSON.stringify(PATHS)}`);
  setInterval(() => {
    credit = Math.min(credit + (RATE * PERIOD_MS) / 1000, RATE);
    while (credit >= 1 && inflight < MAX_INFLIGHT) {
      credit -= 1;
      inflight += 1;
      hit().then(() => { inflight -= 1; });
    }
  }, PERIOD_MS);
} else {
  console.log(`loadgen: ${CONC} workers (closed loop) -> ${BASE} ${JSON.stringify(PATHS)}`);
  for (let i = 0; i < CONC; i++) worker();
}
