FROM debian:bookworm-slim
COPY qmesh-node /qmesh-node
# The fleet console rides along so `fly ssh console` renders cards +
# the incident timeline with root-cause fingerprints from anywhere in
# the 6pn (deploy/smoke/RUNBOOK.md).
COPY qmesh-top /qmesh-top
ENTRYPOINT ["/qmesh-node"]
