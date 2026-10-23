// Test utility (not part of the demo run): deliberately fill the project's connection
// slots so we can verify the fix still applies at the ceiling. Reproduces, in ~30s, the
// state the cascade takes ~20min to reach:
//   "remaining connection slots are reserved for roles with the SUPERUSER attribute"
// Holds the connections until killed. Usage on the box:  node /opt/demoapp/hog.js
const fs = require('fs');
const { Client } = require('pg');

const N = Number(process.env.N || 50);
const REF = process.env.SB_REF;
if (!REF) {
  throw new Error('SB_REF is required: your Supabase project ref. See .env.example');
}
const TARGET = process.env.SB_TARGET || 'prebaked';
const PW = (process.env.SB_PW
  || fs.readFileSync(`${process.env.SECRETS_DIR || '/opt/demoapp/secrets'}/pw_${TARGET}`, 'utf8')).trim();

const held = [];
let refused = 0;

(async () => {
  await Promise.all(Array.from({ length: N }, async () => {
    const c = new Client({
      host: process.env.PGHOST || 'aws-0-us-east-1.pooler.supabase.com',
      port: Number(process.env.PGPORT || 5432),
      user: `postgres.${REF}`,
      password: PW,
      database: 'postgres',
      ssl: { rejectUnauthorized: false },
      connectionTimeoutMillis: 12000,
      application_name: 'demo-hog',
    });
    c.on('error', () => {});
    try { await c.connect(); await c.query('select 1'); held.push(c); } catch (e) { refused++; }
  }));
  console.log(`hog: held=${held.length} refused=${refused}`);
  setInterval(() => {}, 1000);   // keep the slots occupied until killed
})();
