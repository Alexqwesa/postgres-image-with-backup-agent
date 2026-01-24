# ---- Stage 1: build native Dart binary
FROM dart:stable AS build
WORKDIR /src/backup_agent

# 1) cache deps
COPY backup_agent/pubspec.yaml backup_agent/pubspec.lock* ./
RUN dart pub get

# 2) copy sources
COPY backup_agent/ ./

RUN mkdir -p /out
RUN dart compile exe bin/backup_agent.dart -o /out/pgdump-agent

# ---- Stage 2: Postgres with tiny Dart agent
FROM postgres:16.3
COPY --from=build /out/pgdump-agent /usr/local/bin/pgdump-agent
COPY --from=build /src/backup_agent/with-agent.sh /usr/local/bin/with-agent.sh
# Fail if CRLF is present
RUN if grep -n $'\r' /usr/local/bin/with-agent.sh; then \
      echo "ERROR: CRLF detected in with-agent.sh (must be LF)"; \
      exit 1; \
    fi
RUN chmod +x /usr/local/bin/pgdump-agent /usr/local/bin/with-agent.sh
ENTRYPOINT ["/usr/local/bin/with-agent.sh"]
