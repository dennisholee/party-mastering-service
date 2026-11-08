# Local demo image: Envoy plus the controls ext_proc binary built from the
# sibling controls-core checkout. Production uses the controls-sidecar Helm
# library with a signed bundle and a pinned image digest.
FROM envoyproxy/envoy:v1.40.0
ARG EXTPROC_BIN=.tmp/extproc
COPY ${EXTPROC_BIN} /usr/local/bin/extproc
COPY sidecar/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
