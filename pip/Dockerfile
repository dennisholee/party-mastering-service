FROM alpine:3.20
ARG PIP_BIN=.tmp/pip
RUN adduser -D -u 10001 controls
COPY ${PIP_BIN} /usr/local/bin/pip
COPY pip/attributes.json /etc/controls/attributes.json
RUN chmod 0644 /etc/controls/attributes.json
USER controls
ENTRYPOINT ["/usr/local/bin/pip"]
