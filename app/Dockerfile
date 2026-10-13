# syntax=docker/dockerfile:1

# ---- build stage: compile wheels for all dependencies ----
FROM python:3.14-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ---- runtime stage: small image, non-root user ----
FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BIND=0.0.0.0:8000

RUN useradd --create-home --uid 10001 app \
 && mkdir -p /app/instance && chown app:app /app/instance
WORKDIR /app

COPY --from=build /wheels /wheels
RUN pip install --no-cache-dir /wheels/* && rm -rf /wheels

COPY --chown=app:app magic ./magic
COPY --chown=app:app data ./data
COPY --chown=app:app wsgi.py gunicorn.conf.py ./

USER app
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3)" || exit 1

CMD ["gunicorn", "-c", "gunicorn.conf.py", "wsgi:app"]
