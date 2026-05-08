FROM ghcr.io/project-osrm/osrm-backend:latest

RUN apt-get update && apt-get install -y \
    wget \
    nginx \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# nginx proxies all profiles on a single public port
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
