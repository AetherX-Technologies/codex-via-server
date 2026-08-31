FROM ubuntu@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl iproute2 jq nginx openssh-server procps python3 \
    && find /var/lib/apt/lists -mindepth 1 -delete \
    && mkdir -p /run/sshd

COPY server /app/server

RUN chmod 0755 \
        /app/server/install.sh \
        /app/server/install-restricted-user.sh \
        /app/server/codex-via-server-devices \
        /app/server/doctor.sh \
        /app/server/canary.sh \
        /app/server/update-cliproxyapi.sh \
    && ssh-keygen -A

WORKDIR /app
