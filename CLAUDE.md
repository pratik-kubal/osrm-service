# CLAUDE.md — OSRM on Fly.io

This is a self-hosted, city-agnostic OSRM routing service deployable to Fly.io.
It was originally built for a Philadelphia Porchfest map but is designed to serve
any region, event, or application that needs open-source pedestrian/cycling/driving
routing without Google Maps API costs.

---

## What this repo does

- Runs an [OSRM](https://project-osrm.org/) routing engine inside Docker on Fly.io
- Downloads any Geofabrik `.osm.pbf` region on first boot
- Preprocesses the data (extract → partition → customize) once, then persists it
  on a Fly volume so restarts are fast (~10s) not slow (~10min)
- Exposes a standard OSRM HTTP API at port 5000
- All region, profile, and port config is driven by environment variables — no
  code changes needed to switch cities or use cases

---

## Repo structure

```
osrm-fly/
├── CLAUDE.md              ← you are here (Claude Code reads this first)
├── Dockerfile             ← builds on official osrm-backend image
├── entrypoint.sh          ← first-boot build logic + server startup
├── fly.toml               ← Fly.io app config (VM, volume, health check)
├── .env.example           ← template for local dev env vars
├── .gitignore             ← excludes OSM data files from git
└── scripts/
    └── clip-region.sh     ← optional: clips a large .pbf to a bbox with osmium
```

---

## Architecture — multi-profile routing

Each profile runs as its own `osrm-routed` process on a dedicated internal port.
`nginx` listens publicly on `8080` and routes requests by the OSRM profile name
already present in the standard URL path. No custom prefix needed.

```
Client request
    ↓
nginx :8080
    ├── /route/v1/foot/*    or /route/v1/walking/*  → osrm-routed :5000 (foot)
    ├── /route/v1/driving/*                         → osrm-routed :5001 (car)
    └── /route/v1/cycling/* or /route/v1/bike/*     → osrm-routed :5002 (bike)
```

`supervisord` manages all `osrm-routed` processes + nginx as a single unit.
Both nginx config and supervisord config are generated dynamically at startup
based on `OSRM_PROFILES` — only enabled profiles get a process and a route.

---

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `OSM_REGION_URL` | ✅ Yes | — | Geofabrik `.osm.pbf` URL or custom hosted URL |
| `OSM_REGION_NAME` | No | `region` | Filename prefix for local OSM files |
| `OSRM_PROFILES` | No | `foot` | Comma-separated: `foot` \| `car` \| `bike` |

`OSM_REGION_URL` must always be set as a **Fly secret** (not in fly.toml):
```bash
fly secrets set OSM_REGION_URL="https://download.geofabrik.de/north-america/us/pennsylvania-latest.osm.pbf"
```

Use fewer profiles to save RAM and reduce first-boot build time:
```bash
# Porchfest (walking event) — fast boot, minimal RAM
OSRM_PROFILES=foot

# Delivery / rideshare app — driving only
OSRM_PROFILES=car

# Full multi-mode
OSRM_PROFILES=foot,car,bike
```

---

## Fly.io deployment (first time)

```bash
# 1. Install Fly CLI
brew install flyctl

# 2. Login
fly auth login

# 3. Create the app (accept existing fly.toml when prompted)
fly launch --no-deploy

# 4. Create persistent volume (stores preprocessed OSM data)
fly volumes create osrm_data --size 5 --region ewr

# 5. Set the OSM region URL as a secret
fly secrets set OSM_REGION_URL="<geofabrik-url>"

# 6. Deploy
fly deploy
```

First deploy: 5–15 min depending on region size (downloads + preprocesses OSM).
All subsequent restarts: ~10 seconds (data already on volume).

---

## Switching regions or use cases

To redeploy for a different city or event:

```bash
# 1. Update the region URL
fly secrets set OSM_REGION_URL="https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf"

# 2. SSH in and wipe the old processed data so entrypoint rebuilds
fly ssh console
rm -rf /data/*
exit

# 3. Redeploy
fly deploy
```

To add or remove profiles:
```bash
# Edit fly.toml [env] OSRM_PROFILES = "foot,bike"
# Wipe only needed if removing a profile (adding is safe without wipe)
fly ssh console -C "rm -rf /data/*"
fly deploy
```

---

## Connecting a frontend

Your OSRM base URL after deploy:
```
https://<your-app-name>.fly.dev
```

nginx routes automatically based on the profile name already in the OSRM URL path — no custom prefix needed.

### Leaflet Routing Machine — profile switcher
```javascript
const OSRM_BASE_URL = process.env.OSRM_BASE_URL || 'http://localhost:8080';

const PROFILES = {
  foot:  { serviceUrl: `${OSRM_BASE_URL}/route/v1`, profile: 'foot' },
  car:   { serviceUrl: `${OSRM_BASE_URL}/route/v1`, profile: 'driving' },
  bike:  { serviceUrl: `${OSRM_BASE_URL}/route/v1`, profile: 'cycling' },
};

let activeProfile = 'foot'; // default for Porchfest

const router = L.Routing.osrmv1({
  serviceUrl: PROFILES[activeProfile].serviceUrl,
  profile:    PROFILES[activeProfile].profile,
});

L.Routing.control({ router, waypoints: [...] }).addTo(map);

// Switch profile at runtime (e.g. from a toggle button)
function switchProfile(profileKey) {
  router.options.profile = PROFILES[profileKey].profile;
  router.route();
}
```

### Angular environment files
```typescript
// src/environments/environment.ts
export const environment = {
  production: false,
  osrmBaseUrl: 'http://localhost:8080'
};

// src/environments/environment.prod.ts
export const environment = {
  production: true,
  osrmBaseUrl: 'https://<your-app-name>.fly.dev'
};
```

### Raw fetch — choose profile per request
```javascript
const BASE = process.env.OSRM_BASE_URL || 'http://localhost:8080';

// profile: 'foot' | 'driving' | 'cycling'
async function getRoute(origin, destination, profile = 'foot') {
  const coords = `${origin.lng},${origin.lat};${destination.lng},${destination.lat}`;
  const res = await fetch(
    `${BASE}/route/v1/${profile}/${coords}?overview=full&geometries=geojson`
  );
  return res.json();
}
```

---

## Useful Fly commands

```bash
fly logs                   # tail live logs
fly status                 # VM + volume health
fly ssh console            # SSH into running machine
fly volumes list           # confirm osrm_data volume is attached
fly secrets list           # verify secrets are set (values hidden)
fly scale vm shared-cpu-4x --memory 4096  # upgrade VM if OOM (3 profiles need ~3-4GB)
fly deploy --no-cache      # force full Docker rebuild
```

---

## Reducing data size with osmium (optional)

The full state-level extracts can be large. Clip to a bounding box first:

```bash
# Install osmium
brew install osmium-tool

# Run the clip script (edit bbox inside the script)
./scripts/clip-region.sh

# Host the clipped .pbf somewhere public (Cloudflare R2, S3, GitHub Releases)
# Then use that URL as OSM_REGION_URL
```

Bounding box finder: https://boundingbox.klokantech.com

---

## RAM guide by region size

| Region | .pbf size | Recommended VM |
|---|---|---|
| Single neighborhood | < 10MB | shared-cpu-1x, 512MB |
| Single city (e.g. Philadelphia) | ~30–60MB | shared-cpu-1x, 1GB |
| State (e.g. Pennsylvania) | ~312MB | shared-cpu-2x, 2GB |
| Large state / multi-state | 500MB+ | shared-cpu-4x, 4GB+ |

---

## Known issues & gotchas

- **First boot health check may fail** — the 120s `grace_period` in fly.toml covers
  most regions. For large extracts, increase it further.
- **Profile changes require a full data rebuild** — always wipe `/data/*` when
  switching between `foot`, `car`, and `bike`.
- **Volume is region-locked** — Fly volumes are pinned to a region. If you change
  `primary_region` in fly.toml, create a new volume in the new region first.
- **CORS** — OSRM doesn't add CORS headers by default. If your frontend is on a
  different domain, add an nginx proxy or a Fly `[[services.http_checks]]` header.
