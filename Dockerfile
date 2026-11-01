# syntax=docker/dockerfile:1
# Multi-arch: runs natively on Apple Silicon (arm64, e.g. OrbStack) and x86_64.
FROM debian:bookworm-slim AS base
ARG TARGETARCH
ARG PWSH_VERSION=7.4.6
ENV DEBIAN_FRONTEND=noninteractive \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libicu72 libssl3 tzdata less \
 && rm -rf /var/lib/apt/lists/*
RUN case "${TARGETARCH:-amd64}" in \
        amd64) arch=x64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/pwsh.tgz "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arch}.tar.gz" \
 && mkdir -p /opt/microsoft/powershell/7 \
 && tar -xzf /tmp/pwsh.tgz -C /opt/microsoft/powershell/7 \
 && chmod +x /opt/microsoft/powershell/7/pwsh \
 && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
 && rm /tmp/pwsh.tgz \
 && pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
WORKDIR /app
COPY Sync/ /app/Sync/
COPY itg-sync /app/itg-sync
RUN chmod +x /app/itg-sync && ln -s /app/itg-sync /usr/local/bin/itg-sync

# docker build --target test .
FROM base AS test
COPY tests/ /app/tests/
RUN pwsh -NoProfile -File /app/tests/run-tests.ps1

FROM base AS runtime
RUN useradd --create-home --uid 1000 sync \
 && mkdir -p /data /export \
 && chown sync:sync /data
USER sync
ENV SYNC_DATA_DIR=/data
VOLUME ["/data"]
ENTRYPOINT ["itg-sync"]
CMD ["help"]
