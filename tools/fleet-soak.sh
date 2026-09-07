#!/usr/bin/env bash
# Local churn soak: N qmesh-node processes over [::1] using the test
# PKI (tests/data node-a..l), everyone publishing periodically, one
# rotating victim killed and restarted every CHURN_SECS. Harvests
# per-node metrics lines and reports convergence, churn resilience,
# delivery ratio, and RSS drift.
#
# Usage: tools/fleet-soak.sh [minutes]   (default 12)
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/qmesh-node
[ -x "$BIN" ] || { echo "build first: zig build"; exit 1; }

MINUTES=${1:-12}
N=12
BASE_PORT=4700
CHURN_SECS=30
OUT=/tmp/qmesh-soak
mkdir -p "$OUT"; rm -f "$OUT"/*.log "$OUT"/report.txt

ids() { # node-a..l digests (pinned in tests/quic_mesh_test.zig)
  cat <<'EOF'
48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143
c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e
dc1d0a48ff1bf15cd5ae2c4f2a338fa1baab5ae5be7da6a1f7e62364789e5777
6d36cf37f9409c27571667756307520f39c7846d9696bd16ff8a3c45c318c8d3
9e2ca08bd0ceabf513ec1352e8ad749bf676cfda55e0d451c91068c16a958663
ef531a6d6d6f198625e0051c74feb69aa9d6896e6fb64664e56554f7c95e4cb9
18cdf9b433ca8675e849879292f123810ae12e6f6feaa92bd806d85679432650
13c0cd105ea3d36e575cfee3e7eecb0fec4f1606e8d30307b7307ff5dff0172a
87f28cec0e9743ad96f90d96ae6064b27f61e9973940de3d3499b760430502df
37f9bb584bf5c6db63830b0ecc4d0a51eed1aac6656bff8af526eccafdd98ce5
b8791ed5f95d7981b8153640aa1fcee42cc8a2dd5814e113bd01db652146bdb3
dcb8a1301be134790e5e4c0a61b5bfdf8cdece75b7113a4d297f12774279abb7
EOF
}

ID=()
while IFS= read -r line; do
  if [ -n "$line" ]; then ID+=("$line"); fi
done < <(ids)
letters=(a b c d e f g h i j k l)
PIDS=()
RSS0=()

start_node() {
  local i=$1
  local port=$((BASE_PORT + i + 1))
  local letter=${letters[$i]}
  local env_args=(QMESH_ID=${ID[$i]} "QMESH_BIND=[::1]:$port"
    QMESH_CERT=tests/data/node-$letter.pem QMESH_KEY=tests/data/node-$letter.key
    QMESH_CA=tests/data/ca.pem QMESH_METRICS_SECS=10 QMESH_PUBLISH_EVERY=10)
  if [ "$i" -gt 0 ]; then
    env_args+=("QMESH_JOIN=${ID[0]}:[::1]:$((BASE_PORT + 1))")
  fi
  env "${env_args[@]}" "$BIN" > "$OUT/node-$letter.log" 2>&1 &
  PIDS[$i]=$!
}

for i in $(seq 0 $((N - 1))); do start_node "$i"; sleep 0.7; done
sleep 10
for i in $(seq 0 $((N - 1))); do
  RSS0[$i]=$(ps -o rss= -p "${PIDS[$i]}" 2>/dev/null | tr -d ' ') || RSS0[$i]=0
done
echo "started $N nodes; initial rss: ${RSS0[*]}" | tee -a "$OUT/report.txt"

END=$((SECONDS + MINUTES * 60))
victim=1
while [ $SECONDS -lt $END ]; do
  sleep "$CHURN_SECS"
  v=$((victim % N)); victim=$((victim + 1))
  [ "$v" -eq 0 ] && continue # never churn the seed
  echo "$(date +%H:%M:%S) killing node-${letters[$v]} (pid ${PIDS[$v]})" >> "$OUT/report.txt"
  kill -TERM "${PIDS[$v]}" 2>/dev/null || true
  sleep 5
  echo "$(date +%H:%M:%S) restarting node-${letters[$v]}" >> "$OUT/report.txt"
  start_node "$v"
done

sleep 30
{
  echo "=== final state (last metrics line per node) ==="
  for i in $(seq 0 $((N - 1))); do
    letter=${letters[$i]}
    rss1=$(ps -o rss= -p "${PIDS[$i]}" 2>/dev/null | tr -d ' ' || echo gone)
    last=$(grep '^metrics' "$OUT/node-$letter.log" | tail -1)
    echo "node-$letter rss=${RSS0[$i]}->$rss1 $last"
  done
  echo "=== delivery (broadcast lines per node) ==="
  for i in $(seq 0 $((N - 1))); do
    letter=${letters[$i]}
    echo "node-$letter delivered=$(grep -c '^broadcast' "$OUT/node-$letter.log" 2>/dev/null || echo 0)"
  done
} | tee -a "$OUT/report.txt"

for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
wait 2>/dev/null || true
echo "soak complete; logs in $OUT"
