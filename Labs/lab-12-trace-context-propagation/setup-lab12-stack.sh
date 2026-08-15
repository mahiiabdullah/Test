#!/usr/bin/env bash
# setup-lab12-stack.sh
# Self-contained bootstrapper for Lab 12. Brings up Tempo + Grafana,
# installs redis-server, creates a venv with Flask + Celery + Redis +
# the OTel SDK and instrumentations, and writes tasks.py / app.py
# configured for context propagation. Idempotent.

set -euo pipefail

# 0. python3-venv on a fresh Debian/Ubuntu container.
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
  echo "Installing python3-venv (matched to active interpreter)..."
  sudo apt-get update
  PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  if ! sudo apt-get install -y "python${PYV}-venv" python3-pip python3-distutils; then
    if ! sudo apt-get install -y python3-venv python3-pip python3-distutils; then
      echo "ERROR: failed to install a working python3-venv package." >&2
      echo "       Run manually:  sudo apt install python${PYV}-venv python3-pip" >&2
      exit 1
    fi
  fi
  if ! python3 -m venv --help >/dev/null 2>&1 || ! python3 -m ensurepip --version >/dev/null 2>&1; then
    echo "ERROR: python3-venv / ensurepip still not usable after apt install." >&2
    echo "       Try installing one of these manually:" >&2
    echo "         sudo apt install python${PYV}-venv python${PYV}-distutils python3-pip" >&2
    echo "         sudo apt install python3.X-venv python3.X-full" >&2
    exit 1
  fi
fi

# 0a. redis-server.
if ! command -v redis-server >/dev/null 2>&1; then
  echo "Installing redis-server..."
  sudo apt-get update
  sudo apt-get install -y redis-server
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

if [ -d .venv ]; then
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

# 10. tasks.py — worker side, uses extract(carrier).
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

# 11. app.py — Flask side, uses inject(carrier).
cat > app.py <<'PYEOF'
from flask import Flask, jsonify, request
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
    task_result = process_item.delay(item_id, carrier=carrier)
    return jsonify({
        "task_id": task_result.id,
        "trace_id": format(trace.get_current_span().get_span_context().trace_id, "032x"),
    })
PYEOF

deactivate 2>/dev/null || true

echo
echo "Stack is up. Container ports bound (host -> container):"
echo "  ${GRAFANA_PORT} -> Grafana UI (admin / admin)"
echo "  ${TEMPO_QUERY_PORT} -> Tempo query API"
echo "  ${TEMPO_OTLP_PORT} -> Tempo OTLP HTTP receiver"
echo "  ${FLASK_PORT} -> Flask API (POST /process)"
echo
echo "Python virtual environment: .venv  (activate with 'source .venv/bin/activate')"
echo "Celery worker: 'celery -A tasks worker --loglevel=info'"
echo "Flask app: app.py  (POST /process -> enqueues process_item task)"
echo
echo "The chosen ports are saved in .stack-ports for later steps."
echo "Next: open the Load Balancer modal and expose ${TEMPO_OTLP_PORT}, ${TEMPO_QUERY_PORT}, ${GRAFANA_PORT}, and ${FLASK_PORT} on LB_IP"
echo "      (the first IP from 'hostname -I')."