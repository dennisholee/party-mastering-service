# Sidecar image (demo)

`Dockerfile` builds a standalone Envoy + ext_proc image for the local demo.
`entrypoint.sh` is copied verbatim from
`controls-core/deploy/sidecar/entrypoint.sh`; `make entrypoint-check` fails if
the two diverge. The production path is the `controls-sidecar` Helm library,
not this image.
