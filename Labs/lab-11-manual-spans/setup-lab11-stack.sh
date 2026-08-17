#!/usr/bin/env bash
# setup-lab11-stack.sh
# Self-contained bootstrapper for Lab 11. Mirrors setup-lab9-stack.sh
# (Tempo + Grafana + free-port picker + .venv + OTEL packages), then
# writes the manual-spans app.py. Idempotent.

set -euo pipefail

# 0. python3-venv on a fresh Debian/Ubuntu container.
# Run the apt-install FIRST (idempotent — apt skips already-installed
# packages) so the venv module + ensurepip are guaranteed to be present
# before we ever try `python3 -m venv .venv`.
PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Making sure python${PYV}-venv + python3-pip + python${PYV}-distutils are installed..."
sudo apt-get update
# Try version-specific package first (covers Python 3.10+ on modern Debian/Ubuntu).
if ! sudo apt-get install -y "python${PYV}-venv" python3-pip "python${PYV}-distutils"; then
  # Fall back to the generic package name. `|| true` so a single failure
  # doesn't abort the whole script under `set -e`.
  sudo apt-get install -y python3-venv python3-pip python3-distutils || true
fi
# Show the user what is actually available after the install so they can
# verify python3.X-venv really did land before we attempt to use it.
echo "--- post-apt sanity check ---"
dpkg -l "python${PYV}-venv" 2>/dev/null | tail -1 || true
"python${PYV}" -m venv --help 2>&1 | head -3 || true
"python${PYV}" -m ensurepip --version 2>&1 | head -1 || true
echo "-----------------------------"

# Probe whether `python3 -m venv .venv` would actually succeed. `venv --help`
# only checks that the module loads, NOT that ensurepip is usable, so we
# also probe `ensurepip --version` (which is the real culprit on
# Debian 12 / Python 3.12 base images).
need_venv=0
if ! python3 -m venv --help >/dev/null 2>&1; then
  need_venv=1
elif ! python3 -m ensurepip --version >/dev/null 2>&1; then
  need_venv=1
fi
if [ "$need_venv" = "1" ]; then
  echo "ERROR: python3-venv / ensurepip still not usable after apt install." >&2
  echo "       Try installing one of these manually:" >&2
  echo "         sudo apt install python${PYV}-venv python${PYV}-distutils python3-pip" >&2
  echo "         sudo apt install python3.X-venv python3.X-full" >&2
  exit 1
fi

# 0b. Pick free host ports for Tempo/Grafana.
pick_port () {
  local base=$1
  local p=$base
  while [ "$p" -lt $((base + 100)) ]; do
    if ! (echo > "/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo "$base"
}

TEMPO_OTLP_PORT=$(pick_port 4318)
TEMPO_QUERY_PORT=$(pick_port 3200)
GRAFANA_PORT=$(pick_port 3000)
export TEMPO_OTLP_PORT TEMPO_QUERY_PORT GRAFANA_PORT

echo "Using host ports: Tempo OTLP=$TEMPO_OTLP_PORT  Tempo query=$TEMPO_QUERY_PORT  Grafana=$GRAFANA_PORT"

# 1. Project directory.
# Prefer the caller's CWD so the script picks up wherever the user ran
# `curl ... | bash`, and avoids re-creating a nested folder when this
# script is downloaded into a directory that already matches the lab name.
PROJECT_DIR="${1:-${PWD:-$(pwd)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
# Only fall back to SCRIPT_DIR if it's not already an ancestor of PROJECT_DIR
# (this prevents the nested `lab-11-manual-spans/lab-11-manual-spans/` pattern).
if [ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "$SCRIPT_DIR" ]; then
  PROJECT_DIR="$SCRIPT_DIR"
fi
cd "$PROJECT_DIR"
mkdir -p grafana/provisioning/datasources

# 2. docker-compose.yml.
cat > docker-compose.yml <<EOF
services:
  tempo:
    image: grafana/tempo:latest
    command: ["-config.file=/etc/tempo.yml"]
    volumes:
      - ./tempo.yml:/etc/tempo.yml:ro
      - tempo-data:/var/tempo
    ports:
      - "${TEMPO_QUERY_PORT}:3200"
      - "${TEMPO_OTLP_PORT}:4318"

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "${GRAFANA_PORT}:3000"
    depends_on:
      - tempo

volumes:
  tempo-data:
EOF

# 3. Tempo config.
cat > tempo.yml <<'EOF'
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        http:
          endpoint: 0.0.0.0:4318

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
EOF

# 4. Grafana provisioning.
cat > grafana/provisioning/datasources/tempo.yaml <<'EOF'
apiVersion: 1

datasources:
  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    isDefault: true
    editable: true
EOF

# 5. Bring the stack up.
docker compose up -d
docker compose ps

# 6. Health check.
echo "Tempo  ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${TEMPO_QUERY_PORT}/ready)"
echo "Grafana ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${GRAFANA_PORT}/api/health)"

# 7. Save chosen ports.
cat > .stack-ports <<EOF
TEMPO_OTLP_PORT=${TEMPO_OTLP_PORT}
TEMPO_QUERY_PORT=${TEMPO_QUERY_PORT}
GRAFANA_PORT=${GRAFANA_PORT}
EOF

# 8. venv + OTEL packages.
# Try python3 -m venv first, fall back to `uv` (works without ensurepip),
# fall back to pip --user --break-system-packages.
PYBIN=""
# If a previous run left a half-broken .venv (no python3 binary inside),
# nuke it and recreate.
if [ -d .venv ] && [ ! -x .venv/bin/python3 ]; then
  echo "Removing half-created .venv from a previous failed run..."
  rm -rf .venv
fi
if [ ! -d .venv ]; then
  echo "Creating Python virtual environment..."
  if ! python3 -m venv .venv 2>/tmp/.venv.err; then
    echo "WARN: python3 -m venv failed ($(head -1 /tmp/.venv.err)). Trying uv..."
    if ! command -v uv >/dev/null 2>&1; then
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://astral.sh/uv/install.sh | sh
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://astral.sh/uv/install.sh | sh
      fi
      # shellcheck disable=SC1091
      [ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"
      export PATH="$HOME/.local/bin:$PATH"
    fi
    if command -v uv >/dev/null 2>&1; then
      uv venv .venv
    else
      echo "WARN: uv install failed. Falling back to pip --user --break-system-packages."
      rm -rf .venv
      PYBIN="python3 --break-system-packages"
    fi
  fi
fi

if [ -d .venv ] && [ -x .venv/bin/python3 ]; then
  # shellcheck disable=SC1091
  if [ -f .venv/bin/activate ]; then
    source .venv/bin/activate || echo "WARN: failed to source .venv/bin/activate; using system python."
  fi
  PYBIN="${PYBIN:-python}"
fi

if [ -z "$PYBIN" ]; then
  echo "ERROR: could not set up a Python environment (venv / uv / user-site all failed)." >&2
  exit 1
fi

$PYBIN -m pip install --upgrade pip >/dev/null
$PYBIN -m pip install --quiet \
  flask \
  opentelemetry-distro \
  opentelemetry-exporter-otlp-proto-http \
  opentelemetry-instrumentation-flask \
  opentelemetry-instrumentation-requests \
  opentelemetry-instrumentation-urllib3

# 9. The Lab 11 final app.py — root span + two nested child spans.
cat > app.py <<'PYEOF'
import time
from flask import Flask
from opentelemetry import trace

app = Flask(__name__)
tracer = trace.get_tracer(__name__)

@app.get("/hello")
def hello():
    user_id = "u-42"
    request_id = "r-1001"
    with tracer.start_as_current_span("handle_request") as root:
        root.set_attribute("user.id", user_id)
        root.set_attribute("request.id", request_id)

        with tracer.start_as_current_span("db_lookup") as db:
            start = time.perf_counter()
            time.sleep(0.03)
            elapsed_ms = (time.perf_counter() - start) * 1000
            db.set_attribute("db.query_time_ms", round(elapsed_ms, 2))
            db.set_attribute("db.system", "postgres")

        with tracer.start_as_current_span("cache_check") as cache:
            start = time.perf_counter()
            time.sleep(0.01)
            elapsed_ms = (time.perf_counter() - start) * 1000
            cache.set_attribute("cache.lookup_time_ms", round(elapsed_ms, 2))
            cache.set_attribute("cache.hit", False)

        return {"message": "hello from instrumented api"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PYEOF

deactivate 2>/dev/null || true

echo
echo "Stack is up. Container ports bound (host -> container):"
echo "  ${GRAFANA_PORT} -> Grafana UI (admin / admin)"
echo "  ${TEMPO_QUERY_PORT} -> Tempo query API"
echo "  ${TEMPO_OTLP_PORT} -> Tempo OTLP HTTP receiver"
echo
echo "Python virtual environment: .venv  (activate with 'source .venv/bin/activate')"
echo "Flask app: app.py  (serves GET /hello on port 5000 with manual nested spans)"
echo
echo "The chosen ports are saved in .stack-ports for later steps."
echo "Next: open the Load Balancer modal and expose ${TEMPO_OTLP_PORT}, ${TEMPO_QUERY_PORT}, ${GRAFANA_PORT}, and 5000 on LB_IP"
echo "      (the first IP from 'hostname -I')."