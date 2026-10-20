"""Demo service for the GitOps canary rollout.

Deliberately minimal, but it does one important thing: it exports
`http_requests_total` labelled with `service` and `status`. The AnalysisTemplate
queries exactly that metric during a rollout, so without these labels the
automated canary gate would have nothing to measure.

A `/fail` endpoint is included to make rollback testable: force errors, watch
the analysis fail, and confirm the rollout reverts automatically.
"""

import os
import time

from flask import Flask, Response, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    generate_latest,
)

app = Flask(__name__)

VERSION = os.environ.get("VERSION", "dev")
SERVICE = os.environ.get("SERVICE_NAME", "demo-app")

# The metric the canary analysis depends on. `service` distinguishes canary from
# stable traffic, `status` supplies the 2xx ratio the success condition checks.
REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["service", "status", "path"],
)

# Flipped by /fail to simulate a bad release.
FAILING = {"on": False}


@app.before_request
def count_request() -> None:
    """Record every request except scrapes, so metrics are not self-counting."""
    if request.path != "/metrics" and not FAILING["on"]:
        REQUESTS.labels(service=SERVICE, status="200", path=request.path).inc()


@app.get("/")
def index() -> Response:
    return jsonify(
        service=SERVICE,
        version=VERSION,
        host=os.uname().nodename,
        message=f"hello from {VERSION}",
    )


@app.get("/healthz")
def healthz() -> Response:
    return jsonify(status="ok", version=VERSION)


@app.get("/fail")
def fail() -> Response:
    """Turn on simulated failure so the canary analysis can be exercised."""
    FAILING["on"] = True
    for _ in range(50):
        REQUESTS.labels(service=SERVICE, status="500", path="/").inc()
    return jsonify(failing=True, version=VERSION)


@app.get("/recover")
def recover() -> Response:
    FAILING["on"] = False
    return jsonify(failing=False, version=VERSION)


@app.get("/work")
def work() -> Response:
    """Small amount of CPU work, so latency metrics have something to show."""
    total = sum(i * i for i in range(200_000))
    return jsonify(result=total, version=VERSION, ts=time.time())


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
