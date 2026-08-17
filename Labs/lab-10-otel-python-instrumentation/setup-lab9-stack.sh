#!/usr/bin/env bash
# setup-lab9-stack.sh
# Brings up the same Grafana + Tempo stack that Lab 9 uses, so Lab 10
# can run as a self-contained exercise. Idempotent: safe to re-run.

set -euo pipefail

# 0. Make sure python3-venv is available. On a fresh Debian/Ubuntu
#    container, ensurepip is missing and `python3 -m venv` errors out
#    with "externally-managed-environment". Install the metapackage,
#    falling back to the versioned variant if the metapackage is
#    unavailable.
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

# 0b. Pick host ports that are not already in use. Poridhi lab containers
#     occasionally leave a previous Grafana/Tempo stack bound to the
#     default ports (3000/3200/4318), which makes "port is already
#     allocated" fail the new container. Probe each candidate and fall
#     back to the first free port above it.
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

# 1. Pick the project directory (defaults to the script's own folder).
PROJECT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$PROJECT_DIR"

mkdir -p grafana/provisioning/datasources

# 2. Compose stack. The chosen host ports are written in literally.
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

# 3. Tempo config — opens the OTLP HTTP receiver on 0.0.0.0:4318.
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

# 4. Grafana provisioning — Tempo datasource via the docker service name.
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

# 6. Health check (against the host ports we actually bound).
echo "Tempo  ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${TEMPO_QUERY_PORT}/ready)"
echo "Grafana ready? $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${GRAFANA_PORT}/api/health)"

# 7. Persist the chosen ports so the caller (lab README) can pick them up
#    without re-running the probe.
cat > .stack-ports <<EOF
TEMPO_OTLP_PORT=${TEMPO_OTLP_PORT}
TEMPO_QUERY_PORT=${TEMPO_QUERY_PORT}
GRAFANA_PORT=${GRAFANA_PORT}
EOF

# 8. Also create the Python virtual environment and install Flask + the
#    OpenTelemetry packages now. Doing this here means the rest of the
#    lab is just "source the venv and run the wrapper", and the user's
#    fresh container is bootstrapped by a single command.
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
    echo "WARN: python3 -m venv failed. Trying uv..."
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
  echo "Virtual environment ready: $(pwd)/.venv  (Python: $($PYBIN --version 2>&1))"
else
  echo "WARN: no .venv created; using system python with PEP 668 bypass."
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

# 9. Drop a tiny Flask app too, so the user can skip Step 3's "cat > app.py".
if [ ! -f app.py ]; then
  cat > app.py <<'PYEOF'
from flask import Flask

app = Flask(__name__)

@app.get("/hello")
def hello():
    return {"message": "hello from instrumented api"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PYEOF
fi

deactivate 2>/dev/null || true

echo
echo "Stack is up. Container ports bound (host -> container):"
echo "  ${GRAFANA_PORT} -> Grafana UI (admin / admin)"
echo "  ${TEMPO_QUERY_PORT} -> Tempo query API"
echo "  ${TEMPO_OTLP_PORT} -> Tempo OTLP HTTP receiver"
echo
echo "Project directory: $(pwd)"
echo "Python virtual environment: $(pwd)/.venv  (activate with 'source .venv/bin/activate')"
echo "Flask app: app.py  (serves GET /hello on port 5000)"
echo
echo "The chosen ports are saved in .stack-ports for later steps."
echo "Next: open the Load Balancer modal and expose ${TEMPO_OTLP_PORT}, ${TEMPO_QUERY_PORT}, and ${GRAFANA_PORT} on LB_IP"
echo "      (the first IP from 'hostname -I')."
