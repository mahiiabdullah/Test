#!/usr/bin/env bash
# setup-lab13-stack.sh
# Self-contained bootstrapper for Lab 13. Same as Lab 12 (Tempo +
# Grafana + Redis + venv + Flask + Celery + Redis + OTel), but the
# shipped app.py adds the X-Trace-ID response header. Idempotent.

set -euo pipefail

# 0. python3-venv on a fresh Debian/Ubuntu container.
# Run the apt-install FIRST (idempotent — apt skips already-installed
# packages) so the venv module + ensurepip are guaranteed to be present
# before we ever try `python3 -m venv .venv`.
# NOTE: distutils was removed in Python 3.12 and is NOT a separate apt
# package on Ubuntu Noble. Do not try to install python3.12-distutils —
# it doesn't exist, and trying makes the whole install line fail.
PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Making sure python${PYV}-venv + python3-pip are installed..."
sudo apt-get update
# Try version-specific package first (covers Python 3.10+ on modern Debian/Ubuntu).
if ! sudo apt-get install -y "python${PYV}-venv" python3-pip; then
  # Fall back to the generic package name. `|| true` so a single failure
  # doesn't abort the whole script under `set -e`.
  sudo apt-get install -y python3-venv python3-pip || true
fi
# Last resort: some minimal base images strip pip entirely. Try
# python3.X-full which bundles venv + ensurepip + pip + distutils.
if ! python3 -m ensurepip --version >/dev/null 2>&1; then
  echo "ensurepip still missing; trying python${PYV}-full as a last resort..."
  sudo apt-get install -y "python${PYV}-full" || sudo apt-get install -y python3-full || true
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

# 0a. redis-server.
if ! command -v redis-server >/dev/null 2>&1; then
  echo "Installing redis-server..."
  sudo apt-get update
  sudo apt-get install -y redis-server
fi

# 0b. Pick free host ports for Tempo/Grafana/Flask.
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
FLASK_PORT=$(pick_port 8000)
export TEMPO_OTLP_PORT TEMPO_QUERY_PORT GRAFANA_PORT FLASK_PORT

echo "Using host ports: Tempo OTLP=$TEMPO_OTLP_PORT  Tempo query=$TEMPO_QUERY_PORT  Grafana=$GRAFANA_PORT  Flask=$FLASK_PORT"

# 1. Project directory.
PROJECT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
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
FLASK_PORT=${FLASK_PORT}
EOF

# 8. venv + the project packages.
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
  celery \
  redis \
  opentelemetry-api \
  opentelemetry-sdk \
  opentelemetry-exporter-otlp-proto-http \
  opentelemetry-instrumentation-flask \
  opentelemetry-instrumentation-celery \
  opentelemetry-instrumentation-requests \
  opentelemetry-instrumentation-urllib3

# 9. Start redis-server in the background if it is not already up.
if ! (echo > "/dev/tcp/127.0.0.1/6379") >/dev/null 2>&1; then
  echo "Starting redis-server..."
  nohup redis-server --daemonize yes >/tmp/redis.log 2>&1 || true
  sleep 1
fi
echo "Redis ready? $(redis-cli ping 2>/dev/null || echo no)"

# 10. tasks.py — same as Lab 12.
cat > tasks.py <<'PYEOF'
import socket
from celery import Celery
from opentelemetry import trace
from opentelemetry.propagate import extract

celery_app = Celery(
    "trace-lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/0",
)
tracer = trace.get_tracer(__name__)


@celery_app.task(name="trace-lab.process_item")
def process_item(item_id, carrier=None):
    ctx = extract(carrier or {})
    with tracer.start_as_current_span("celery-process", context=ctx) as span:
        span.set_attribute("item.id", item_id)
        span.set_attribute("worker.hostname", socket.gethostname())
        result = do_work(item_id)
        span.set_attribute("result.size", len(result))
        return result


def do_work(item_id):
    return f"processed {item_id}"
PYEOF

# 11. app.py — Labs 11/12 PLUS the X-Trace-ID response header.
cat > app.py <<'PYEOF'
from flask import Flask, jsonify, request, make_response
from celery import Celery
from tasks import celery_app, process_item
from opentelemetry import trace
from opentelemetry.propagate import inject

flask_app = Flask(__name__)
flask_app.config["CELERY_BROKER_URL"] = "redis://localhost:6379/0"
flask_app.config["CELERY_RESULT_BACKEND"] = "redis://localhost:6379/0"
celery_app.conf.update(broker_url=flask_app.config["CELERY_BROKER_URL"])
tracer = trace.get_tracer(__name__)


@flask_app.post("/process")
def enqueue_process():
    item_id = request.json.get("item_id")
    carrier = {}
    inject(carrier)
    process_item.delay(item_id, carrier=carrier)
    span = trace.get_current_span()
    trace_id_hex = format(span.get_span_context().trace_id, "032x")
    response = make_response(jsonify({"task_id": "...", "trace_id": trace_id_hex}))
    response.headers["X-Trace-ID"] = trace_id_hex
    return response
PYEOF

# 11a. Slow-app variant used by Step 7 below. Available but NOT used by
#      default — the README's Step 7 tells the user to swap in this
#      version themselves to demonstrate attribution.
cat > tasks_slow.py <<'PYEOF'
import socket
import time
from celery import Celery
from opentelemetry import trace
from opentelemetry.propagate import extract

celery_app = Celery(
    "trace-lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/0",
)
tracer = trace.get_tracer(__name__)


@celery_app.task(name="trace-lab.process_item")
def process_item(item_id, carrier=None):
    ctx = extract(carrier or {})
    with tracer.start_as_current_span("celery-process", context=ctx) as span:
        span.set_attribute("item.id", item_id)
        span.set_attribute("worker.hostname", socket.gethostname())
        result = do_work(item_id)
        span.set_attribute("result.size", len(result))
        return result


def do_work(item_id):
    time.sleep(2)  # injected latency for the attribution experiment
    return f"processed {item_id}"
PYEOF

deactivate 2>/dev/null || true

echo
echo "Stack is up. Container ports bound (host -> container):"
echo "  ${GRAFANA_PORT} -> Grafana UI (admin / admin)"
echo "  ${TEMPO_QUERY_PORT} -> Tempo query API"
echo "  ${TEMPO_OTLP_PORT} -> Tempo OTLP HTTP receiver"
echo "  ${FLASK_PORT} -> Flask API (POST /process, sets X-Trace-ID)"
echo
echo "Python virtual environment: .venv  (activate with 'source .venv/bin/activate')"
echo "Celery worker: 'celery -A tasks worker --loglevel=info'"
echo "Flask app: app.py  (POST /process -> enqueues process_item task; returns X-Trace-ID)"
echo "Slow-worker variant: tasks_slow.py  (used in Step 7 to inject latency)"
echo
echo "The chosen ports are saved in .stack-ports for later steps."
echo "Next: open the Load Balancer modal and expose ${TEMPO_OTLP_PORT}, ${TEMPO_QUERY_PORT}, ${GRAFANA_PORT}, and ${FLASK_PORT} on LB_IP"
echo "      (the first IP from 'hostname -I')."