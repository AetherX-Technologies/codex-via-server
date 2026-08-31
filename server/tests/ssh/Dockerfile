FROM ubuntu@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates openssh-server python3 \
    && find /var/lib/apt/lists -mindepth 1 -delete

COPY server/install-restricted-user.sh /app/server/install-restricted-user.sh
COPY server/sshd/codex-tunnel.conf /app/server/sshd/codex-tunnel.conf
COPY server/tests/ssh/entrypoint.sh /app/entrypoint.sh
COPY server/tests/ssh/mock-gateway.py /app/mock-gateway.py

RUN chmod 0755 /app/server/install-restricted-user.sh /app/entrypoint.sh \
    && mkdir -p /run/sshd \
    && ssh-keygen -A \
    && /app/server/install-restricted-user.sh

EXPOSE 22

ENTRYPOINT ["/app/entrypoint.sh"]
