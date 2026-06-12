# GHW Docker — quick start

## 1. Build image

```bash
docker build -t ghw:latest .
```

Multi-stage build:
- Stage 1 (`ziglang/static-base:0.17.0-dev.704`): compiles `ui_server` + `daemon`
  with ReleaseSafe optimization
- Stage 2 (`gcr.io/distroless/cc-debian12:nonroot`): minimal runtime
  with only the binaries + UI files

## 2. Run standalone (no monitoring)

```bash
echo "DEEPSEEK_API_KEY=sk-xxx" > .env

docker run -d --name ghw \
  -p 8765:8765 \
  -v ghw_data:/data \
  --env-file .env \
  ghw:latest

# Visit http://localhost:8765
```

## 3. Run with Prometheus + Grafana monitoring (multi-instance)

The default `docker-compose.yml` runs **2 GHW instances** (alpha + bravo)
plus Prometheus + Grafana. This is the production-grade setup showing
multi-agent peer communication (Phase 1 production).

```bash
echo "DEEPSEEK_API_KEY=sk-xxx" > .env
docker compose up -d
```

Then:
- http://localhost:8765 — GHW alpha (UI dashboard)
- http://localhost:8766 — GHW bravo (UI dashboard)
- http://localhost:9090 — Prometheus (scrape both /api/metrics every 15s)
- http://localhost:3000 — Grafana (admin / admin)

The two instances share a `shared_peers` volume (read-only), and each
loads it on startup via `--peers-file`. After ~60s, each instance's
peer health thread will have pinged the other and updated
`/api/peers` to show them as `healthy`.

To run a single instance, override the entrypoint in your own
`docker-compose.override.yml`.

### Grafana dashboard

Import the GHW dashboard:

1. Grafana → Dashboards → Import
2. Upload `docker/grafana-dashboard.json` (or paste JSON)
3. Select Prometheus data source
4. Done — you'll see:
   - E / M / R / N time series
   - Phase progress
   - 9-palace milestones
   - L4 propose rate
   - L1-L5 cumulative counts

## 4. Health check

```bash
docker inspect --format='{{.State.Health.Status}}' ghw
# healthy / unhealthy / starting
```

## 5. Volume

```bash
# 查看数据
docker volume inspect ghw_data

# 备份
docker run --rm -v ghw_data:/data -v $(pwd):/backup \
  alpine tar czf /backup/ghw_data_$(date +%Y%m%d).tar.gz /data

# 恢复
docker run --rm -v ghw_data:/data -v $(pwd):/backup \
  alpine tar xzf /backup/ghw_data_20260101.tar.gz -C /
```

## 6. Zero runtime deps

The image uses `gcr.io/distroless/cc-debian12:nonroot` which has:
- glibc
- libsqlite3 (transitive dep of libghw.a)
- ca-certificates

That's it. No Python, no Node, no Java. The Zig binary is statically
linked (libghw.a bundles libsqlite3), so the only OS deps are libc
and the DNS resolver.

## 7. Production hardening

For real production:

```yaml
# docker-compose.override.yml
services:
  ghw:
    environment:
      - DEEPSEEK_API_KEY_FILE=/run/secrets/deepseek_key  # docker secret
    secrets:
      - deepseek_key

secrets:
  deepseek_key:
    file: ./secrets/deepseek_key.txt
```

Then update the entrypoint to read from `_FILE` env var.

## 8. Multi-arch build

```bash
docker buildx create --use
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghw:latest .
```
