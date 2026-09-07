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

## Findings (open)

1. **Join give-up cold-start race**: `join_max_attempts` (4 × 3s in
   the fly profile) exhausts permanently when the joiner restarts
   while the seed is down — a lone node with an empty table never
   dials again. Mitigation in ops: start the seed first. Fix worth
   making: retry the last contact periodically while the member
   table is empty.

2. **Ephemeral-class probe loss ~25-45% on a pristine path**: probes
   time out (no ACK within 800ms) at a rate far above wire loss —
   ICMP measured 0% loss / 0.1ms jitter between the same machines,
   and the same pattern reproduces on loopback (`::1`) with the fly
   profile (~44%). Not fly-specific, not a today-regression (present
   before the PMTU change), and the mesh self-heals through it (every
   suspicion is refuted or resurrected; stream-class traffic is
   unaffected). Suspects: a datagram-class drop/timeout inside the
   endpoint↔quic seam (asymmetrically swept sessions are one
   candidate; the probe PING is not re-sent when its connect effect
   completes mid-probe is another). The deterministic sim with the
   fly profile is the right place to corner it — if it reproduces
   there, it's a pure-core bug; if not, it's in the real transport
   seam (qlog callback wiring is already in place for that hunt).

## Cost

2 × shared-cpu-1x 256MB ≈ half a cent per hour combined.
