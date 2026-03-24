ARG BASE_IMAGE=postgres:16.3
# ---- Stage 1: build native Dart binary
FROM dart:stable AS build
WORKDIR /src/backup_agent

# 1) cache deps
COPY pubspec.yaml pubspec.lock* ./
RUN dart pub get

# 2) copy sources
COPY . ./

RUN mkdir -p /out
RUN dart compile exe bin/backup_agent.dart -o /out/pgdump-agent

# ---- Stage 2: Postgres with tiny Dart agent

FROM ${BASE_IMAGE}
COPY --from=build /out/pgdump-agent /usr/local/bin/pgdump-agent

# Entrypoints
COPY --from=build /src/backup_agent/docker-entrypoint-with-agent.sh \
  /usr/local/bin/docker-entrypoint-with-agent.sh
COPY --from=build /src/backup_agent/docker-entrypoint-agent-only.sh \
  /usr/local/bin/docker-entrypoint-agent-only.sh

# Fail if CRLF is present (LF only)
RUN if grep -n $'\r' /usr/local/bin/docker-entrypoint-with-agent.sh; then \
      echo "ERROR: CRLF detected in docker-entrypoint-with-agent.sh (must be LF)"; exit 1; fi && \
    if grep -n $'\r' /usr/local/bin/docker-entrypoint-agent-only.sh; then \
      echo "ERROR: CRLF detected in docker-entrypoint-agent-only.sh (must be LF)"; exit 1; fi

# Make binaries executable
RUN chmod +x \
  /usr/local/bin/pgdump-agent \
  /usr/local/bin/docker-entrypoint-with-agent.sh \
  /usr/local/bin/docker-entrypoint-agent-only.sh

# Default: Postgres + agent
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-with-agent.sh"]
CMD ["postgres"]
