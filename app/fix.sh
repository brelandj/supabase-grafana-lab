#!/usr/bin/env bash
# Demo fix, runnable on the EC2 box: adds the missing index via the 6543 transaction
# pooler so it connects even while the session pool is saturated by the fault.
exec node /opt/demoapp/fix.js
