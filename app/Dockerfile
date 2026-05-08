FROM python:3.12-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

# Non-root runtime user (uid 10001).
RUN useradd -u 10001 -r bridge && chown -R bridge /app
USER bridge

# Heartbeat-based liveness. Fails if /tmp/last_poll.json is missing or older
# than 30s (covers a default 10s poll with margin). For substantially larger
# POLL_INTERVAL_SECONDS, override --interval/--start-period in compose.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=2 \
    CMD python -c "import os,sys,time; p='/tmp/last_poll.json'; sys.exit(0) if os.path.exists(p) and time.time()-os.path.getmtime(p) < 30 else sys.exit(1)"

ENTRYPOINT ["python", "-u", "main.py"]
