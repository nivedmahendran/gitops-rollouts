# Multi-stage so the final image carries no build tooling.
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim

# Runs as a non-root user; the Rollout's securityContext also enforces this,
# so the image and the manifest agree rather than relying on one alone.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser

COPY --from=builder /install /usr/local
WORKDIR /app
COPY main.py .

# readOnlyRootFilesystem is true in the manifest, so anything that needs to
# write must be given a writable mount. Python wants a bytecode cache dir.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 10001
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8080/healthz').status==200 else 1)"

CMD ["python", "main.py"]
