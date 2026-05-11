#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# All config via environment variables — see CLAUDE.md or .env.example
#
# OSRM_PROFILES  — comma-separated list of profiles to enable
#                  e.g. "foot,car,bike" or just "foot"
#                  supported values: foot | car | bike
#
# Port assignment (internal, not exposed publicly):
#   foot → 5000
#   car  → 5001
#   bike → 5002
#
# nginx listens on 8080 and routes by OSRM URL path:
#   /route/v1/foot/*    → :5000
#   /route/v1/walking/* → :5000
#   /route/v1/driving/* → :5001
#   /route/v1/cycling/* → :5002
#   /route/v1/bike/*    → :5002
# ---------------------------------------------------------------------------

REGION_NAME="${OSM_REGION_NAME:-region}"
PROFILES="${OSRM_PROFILES:-foot}"   # comma-separated: foot,car,bike
OSM_FILE="/data/${REGION_NAME}.osm.pbf"

declare -A PROFILE_PORT=(
  [foot]=5000
  [car]=5001
  [bike]=5002
)

# OSRM ships profiles in /opt with these filenames; map our short name → lua file
declare -A PROFILE_LUA=(
  [foot]=foot
  [car]=car
  [bike]=bicycle
)

# ---------------------------------------------------------------------------
# 1. Download OSM data (once — reuses file on subsequent boots)
# ---------------------------------------------------------------------------
if [ ! -s "$OSM_FILE" ]; then
  if [ -z "$OSM_REGION_URL" ]; then
    echo "[osrm] ERROR: OSM_REGION_URL is not set."
    echo "  Set it with: fly secrets set OSM_REGION_URL=<geofabrik-url>"
    exit 1
  fi
  [ -f "$OSM_FILE" ] && echo "[osrm] Removing zero-byte $OSM_FILE from a prior failed run." && rm -f "$OSM_FILE"
  echo "[osrm] Downloading: $OSM_REGION_URL"
  wget -q --show-progress -O "$OSM_FILE" "$OSM_REGION_URL"
else
  echo "[osrm] OSM source file found — skipping download."
fi

# ---------------------------------------------------------------------------
# 1b. Optional bbox clip (once — reuses clipped file on subsequent boots)
#     OSM_BBOX format: min_lng,min_lat,max_lng,max_lat
# ---------------------------------------------------------------------------
if [ -n "${OSM_BBOX:-}" ]; then
  CLIPPED_FILE="/data/${REGION_NAME}-clipped.osm.pbf"
  if [ ! -s "$CLIPPED_FILE" ]; then
    [ -f "$CLIPPED_FILE" ] && echo "[osrm] Removing zero-byte $CLIPPED_FILE from a prior failed clip." && rm -f "$CLIPPED_FILE"
    echo "[osrm] Clipping $OSM_FILE to bbox: $OSM_BBOX"
    osmium extract --overwrite --bbox "$OSM_BBOX" --strategy complete_ways \
      --output "$CLIPPED_FILE" "$OSM_FILE"
    echo "[osrm] Clipped file: $(du -h "$CLIPPED_FILE" | cut -f1)"
  else
    echo "[osrm] Clipped file found — skipping clip."
  fi
  OSM_FILE="$CLIPPED_FILE"
fi

# ---------------------------------------------------------------------------
# 2. Process each requested profile (skips if already built)
# ---------------------------------------------------------------------------
IFS=',' read -ra PROFILE_LIST <<< "$PROFILES"

for PROFILE in "${PROFILE_LIST[@]}"; do
  PROFILE=$(echo "$PROFILE" | tr -d ' ')   # trim whitespace
  OSRM_BASE="/data/${REGION_NAME}-${PROFILE}.osrm"

  if [ ! -f "${OSRM_BASE}" ]; then
    echo "[osrm] Building profile: $PROFILE"
    osrm-extract -p "/opt/${PROFILE_LUA[$PROFILE]}.lua" "$OSM_FILE" --output "${OSRM_BASE}"
    osrm-partition "${OSRM_BASE}"
    osrm-customize "${OSRM_BASE}"
    echo "[osrm] Profile $PROFILE ready."
  else
    echo "[osrm] Profile $PROFILE already built — skipping."
  fi
done

# ---------------------------------------------------------------------------
# 3. Generate supervisord config — one [program] block per profile
# ---------------------------------------------------------------------------
SUPERVISORD_CONF="/etc/supervisord.conf"

cat > "$SUPERVISORD_CONF" <<EOF
[supervisord]
nodaemon=true
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[unix_http_server]
file=/var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock
EOF

for PROFILE in "${PROFILE_LIST[@]}"; do
  PROFILE=$(echo "$PROFILE" | tr -d ' ')
  PORT="${PROFILE_PORT[$PROFILE]}"
  OSRM_BASE="/data/${REGION_NAME}-${PROFILE}.osrm"

  cat >> "$SUPERVISORD_CONF" <<EOF

[program:osrm-${PROFILE}]
command=osrm-routed --algorithm mld --port ${PORT} --max-table-size 1000000 ${OSRM_BASE}
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/osrm-${PROFILE}.err.log
stdout_logfile=/var/log/supervisor/osrm-${PROFILE}.out.log
EOF
done

# Always add nginx
cat >> "$SUPERVISORD_CONF" <<EOF

[program:nginx]
command=nginx -g 'daemon off;'
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/nginx.err.log
stdout_logfile=/var/log/supervisor/nginx.out.log
EOF

# ---------------------------------------------------------------------------
# 4. Generate nginx config — routes by OSRM profile in URL path
# ---------------------------------------------------------------------------
NGINX_CONF="/etc/nginx/http.d/osrm.conf"
CORS_SNIPPET="/etc/nginx/snippets/cors.conf"

mkdir -p /etc/nginx/snippets

# OSRM emits its own CORS headers on GET but doesn't answer OPTIONS preflights.
# Strip its headers so we don't get duplicates (which browsers reject), then
# emit one clean set from nginx and short-circuit OPTIONS here.
cat > "$CORS_SNIPPET" <<'CORSEOF'
proxy_hide_header Access-Control-Allow-Origin;
proxy_hide_header Access-Control-Allow-Methods;
proxy_hide_header Access-Control-Allow-Headers;
proxy_hide_header Access-Control-Max-Age;

if ($request_method = OPTIONS) {
    add_header Access-Control-Allow-Origin "*";
    add_header Access-Control-Allow-Methods "GET, OPTIONS";
    add_header Access-Control-Max-Age 86400;
    add_header Content-Type "text/plain";
    add_header Content-Length 0;
    return 204;
}
add_header Access-Control-Allow-Origin "*" always;
add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
add_header Access-Control-Max-Age 86400 always;
CORSEOF

cat > "$NGINX_CONF" <<'NGINXEOF'
server {
    listen 8080;
    server_name _;

    # Health check
    location /health {
        return 200 'ok';
        add_header Content-Type text/plain;
    }

NGINXEOF

for PROFILE in "${PROFILE_LIST[@]}"; do
  PROFILE=$(echo "$PROFILE" | tr -d ' ')
  PORT="${PROFILE_PORT[$PROFILE]}"

  case "$PROFILE" in
    foot)
      cat >> "$NGINX_CONF" <<EOF
    # foot profile — matches /route/v1/foot/* and /route/v1/walking/*
    location ~ ^/(route|table|trip|match|nearest)/v1/(foot|walking) {
        include ${CORS_SNIPPET};
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
    }
EOF
      ;;
    car)
      cat >> "$NGINX_CONF" <<EOF
    # car profile — matches /route/v1/driving/*
    location ~ ^/(route|table|trip|match|nearest)/v1/driving {
        include ${CORS_SNIPPET};
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
    }
EOF
      ;;
    bike)
      cat >> "$NGINX_CONF" <<EOF
    # bike profile — matches /route/v1/cycling/* and /route/v1/bike/*
    location ~ ^/(route|table|trip|match|nearest)/v1/(cycling|bike) {
        include ${CORS_SNIPPET};
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
    }
EOF
      ;;
  esac
done

echo "}" >> "$NGINX_CONF"

# ---------------------------------------------------------------------------
# 5. Start everything via supervisord
# ---------------------------------------------------------------------------
echo "[osrm] Active profiles: $PROFILES"
echo "[osrm] nginx routing on port 8080 → OSRM instances"
echo "[osrm] Starting supervisord..."
exec supervisord -c /etc/supervisord.conf
