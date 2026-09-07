# fly.io smoke test runbook

Two `qmesh-node` machines on opposite ends of North America (sjc +
iad), joined over fly's WireGuard 6pn private network. Executed
2026-09-06 (app `qmesh-smoke-nullstyle`, personal org); this file is
the reproducible procedure plus what it proved and found.

## Procedure

```sh
# 0. Binary: fly shared-cpu machines are x86_64.
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe
mkdir -p /tmp/qmesh-smoke-pki && cd /tmp/qmesh-smoke-pki
cp ../../zig-out/bin/qmesh-node .                       # plus this
                                                    # directory's Dockerfile + fly.toml

# 1. Throwaway PKI (30 days; never production material) + PeerIds.
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 30 \
  -subj "/CN=QMesh Fly Smoke CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.pem
for n in a b; do
  openssl ecparam -name prime256v1 -genkey -noout -out node-$n.key
  openssl req -new -key node-$n.key -subj "/CN=qmesh-$n" -out node-$n.csr
  printf 'subjectAltName=DNS:qmesh,DNS:qmesh-%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth,clientAuth\n' $n > node-$n.ext
  openssl x509 -req -in node-$n.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -sha256 -days 30 -extfile node-$n.ext -out node-$n.pem
done
for n in a b; do echo "node-$n: $(openssl x509 -in node-$n.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER | openssl dgst -sha256 | awk '{print $2}')"; done

# 2. App + image.
fly apps create <app> --org personal
fly deploy --app <app> --now        # first deploy creates one machine

# 3. Second region + private IPs.
fly machine clone <machine-1> --region iad --app <app>
fly machine list --app <app> --json   # note each machine's private_ip

# 4. Wire each machine (fly machine update REPLACES env — pass the
#    full set every time; it restarts the machine).
fly machine update <m1> --app <app> --yes \
  --env QMESH_ID=<id-a> --env "QMESH_BIND=[<ip-1>]:4451" \
  --env QMESH_CERT="$(cat node-a.pem)" --env QMESH_KEY="$(cat node-a.key)" \
  --env QMESH_CA="$(cat ca.pem)" --env QMESH_PUBLISH_EVERY=30 \
  --env QMESH_PMTU_MAX=1372
fly machine update <m2> --app <app> --yes \
  --env QMESH_ID=<id-b> --env "QMESH_BIND=[<ip-2>]:4451" \
  --env "QMESH_JOIN=<id-a>:[<ip-1>]:4451" \
  --env QMESH_CERT="$(cat node-b.pem)" --env QMESH_KEY="$(cat node-b.key)" \
  --env QMESH_CA="$(cat ca.pem)" --env QMESH_PUBLISH_EVERY=30 \
  --env QMESH_PMTU_MAX=1372
fly machine start <m1> --app <app>   # start the seed FIRST, then the joiner

# 5. Watch.
fly logs --app <app> | grep -E "metrics|broadcast|published"
```

Teardown (destructive): `fly apps destroy <app>`.

## What it proved

- mTLS handshake, HELLO identity binding, JOIN/NEIGHBOR, SWIM probes,
  and Plumtree broadcast all work over real 6pn cross-country.
- Broadcast delivery both directions, continuously (every smoke
  publish delivered on the far machine).
- RTT matrix: 76-77ms smoothed app-level RTT each way (ICMP says
  74.5ms ± 0.1 — the ~2ms delta is the QUIC + mesh stack).
- Fly 6pn interface MTU is 1420 → **QMESH_PMTU_MAX must be 1372**
  (1420 − 48 v6+UDP headers). At the old 1380 cap, full-size packets
  (1428B) were silently dropped by the interface.
- Spurious-confirm recovery works live: a gossip send that raced a
  session churn confirmed a live peer; session-evidence resurrection
  (d458e12) re-fused the pair with no operator action.

## Findings (resolved after the first smoke)

1. **Join give-up cold-start race — FIXED**: `join_max_attempts`
   used to exhaust permanently when a joiner restarted while its
   seed was down (empty table => never dials again). A node with no
   active edges now retries its provisioned contact forever. The
   redeploy exercised it directly: the joiner came up before the
   seed and connected the moment the seed appeared.

2. **Ephemeral-class probe loss ~25-45% on a pristine path — ROOT
   CAUSED AND FIXED**: probes timed out at ~25-45% despite 0% ICMP
   loss, reproducing on loopback. Bisected by instrumentation: the
   sim (fly profile, two clean nodes) showed 118 probes / 0
   suspects — pure cores exonerated. Wire-level qlog counters then
   showed the receiving dial-connection dropping genuine peer
   packets with decryption_failure, correlated with key updates.
   The chain: qmesh minted a stateless-reset key by default; a mesh
   node accepts and dials on ONE socket, so every inbound packet
   passes the server first, and the server answered our own dials'
   connection packets with stateless resets — a self-sustaining
   reset ping-pong whose auth-failure noise drove key updates, and
   real traffic died in each update window. Fix: the reset key arms
   only when explicitly provided (like the other deployment keys).
   After: 44 probes / 44 acks / 0 suspects locally; 94/94/0 on fly
   across regions. Diagnosis surface kept: `--qlog-count` /
   `--qlog-dump` wire-event counters, acks_tx/acks_rx and datagram
   shed counters in the metrics line.

## Cost

2 × shared-cpu-1x 256MB ≈ half a cent per hour combined.
