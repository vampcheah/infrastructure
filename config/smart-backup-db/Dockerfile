FROM debian:12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      tzdata \
      gzip \
      coreutils \
      findutils \
      default-mysql-client \
      postgresql-client \
      awscli \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/smart-backup-db

COPY backup.sh restore.sh ./
COPY lib/ ./lib/

RUN chmod +x backup.sh restore.sh

# config.sh and credentials are mounted at runtime — not baked into the image.
# See 002_infrastructure/docker-compose.yml for the mount set.

CMD ["/opt/smart-backup-db/backup.sh"]
