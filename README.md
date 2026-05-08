# osrm-service

Self-hosted, city-agnostic [OSRM](https://project-osrm.org/) routing service deployable to [Fly.io](https://fly.io). Originally built for a Philadelphia Porchfest map, but designed to serve any region or app that needs open-source pedestrian / cycling / driving routing without Google Maps API costs.

## Features

- Runs OSRM inside Docker on Fly.io
- Downloads any Geofabrik `.osm.pbf` region on first boot
- Preprocesses data once (extract → partition → customize), then persists it on a Fly volume — restarts take ~10s instead of ~10min
- Multi-profile support: `foot`, `car`, `bike` — each runs as its own `osrm-routed` process behind nginx
- Standard OSRM HTTP API, no custom URL prefix needed
- All region/profile/port config driven by environment variables

## Architecture

```
Client request
    ↓
nginx :8080
    ├── /route/v1/foot/*    or /route/v1/walking/*  → osrm-routed :5000 (foot)
    ├── /route/v1/driving/*                         → osrm-routed :5001 (car)
    └── /route/v1/cycling/* or /route/v1/bike/*     → osrm-routed :5002 (bike)
```

`supervisord` manages all `osrm-routed` processes plus nginx as a single unit. Both nginx and supervisord configs are generated dynamically at startup from `OSRM_PROFILES` — only enabled profiles get a process and a route.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `OSM_REGION_URL` | Yes | — | Geofabrik `.osm.pbf` URL or custom hosted URL |
| `OSM_REGION_NAME` | No | `region` | Filename prefix for local OSM files |
| `OSRM_PROFILES` | No | `foot` | Comma-separated: `foot` \| `car` \| `bike` |

`OSM_REGION_URL` should always be set as a Fly secret, not in `fly.toml`.

## Quick start (Fly.io)

```bash
# 1. Install Fly CLI and login
brew install flyctl
fly auth login

# 2. Create the app (accept existing fly.toml when prompted)
fly launch --no-deploy

# 3. Create persistent volume for preprocessed OSM data
fly volumes create osrm_data --size 5 --region ewr

# 4. Set the OSM region URL
fly secrets set OSM_REGION_URL="https://download.geofabrik.de/north-america/us/pennsylvania-latest.osm.pbf"

# 5. Deploy
fly deploy
```

First deploy takes 5–15 min depending on region size. Subsequent restarts are ~10 seconds.

## Switching regions

```bash
# Update the region URL
fly secrets set OSM_REGION_URL="https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf"

# Wipe processed data so the entrypoint rebuilds
fly ssh console -C "rm -rf /data/*"

# Redeploy
fly deploy
```

## Frontend usage

Base URL after deploy: `https://<your-app-name>.fly.dev`

```javascript
// profile: 'foot' | 'driving' | 'cycling'
async function getRoute(origin, destination, profile) {
  const coords = `${origin.lng},${origin.lat};${destination.lng},${destination.lat}`;
  const res = await fetch(
    `${BASE}/route/v1/${profile}/${coords}?overview=full&geometries=geojson`
  );
  return res.json();
}
```

Works with [Leaflet Routing Machine](https://www.liedman.net/leaflet-routing-machine/), Mapbox GL Directions, or raw fetch — anything that speaks the OSRM API.

## RAM guide by region size

| Region | .pbf size | Recommended VM |
|---|---|---|
| Single neighborhood | < 10MB | shared-cpu-1x, 512MB |
| Single city (e.g. Philadelphia) | ~30–60MB | shared-cpu-1x, 1GB |
| State (e.g. Pennsylvania) | ~312MB | shared-cpu-2x, 2GB |
| Large state / multi-state | 500MB+ | shared-cpu-4x, 4GB+ |

To shrink large extracts, clip with `osmium` first — see `scripts/clip-region.sh` and use [boundingbox.klokantech.com](https://boundingbox.klokantech.com) to pick a bbox.

## Repo layout

```
├── CLAUDE.md              ← detailed reference for Claude Code
├── Dockerfile             ← builds on official osrm-backend image
├── entrypoint.sh          ← first-boot build logic + server startup
├── fly.toml               ← Fly.io app config
└── scripts/
    └── clip-region.sh     ← optional: clip a large .pbf to a bbox
```

See [`CLAUDE.md`](./CLAUDE.md) for full deployment notes, profile-switching details, troubleshooting, and gotchas.

## License

MIT
