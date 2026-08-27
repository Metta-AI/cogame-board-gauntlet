# Board Gauntlet game + player image. One image, two entrypoints:
#   /bin/board-gauntlet         - the game server (default)
#   /bin/board-gauntlet-player  - the prompt-delivery player
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/board-gauntlet
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The repo nim.cfg pins the host machine's package paths; regenerate it from
# the container's synced package tree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/gauntlet-nimcache --out:board-gauntlet src/gauntlet.nim && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/gauntlet-player-nimcache --out:board-gauntlet-player \
    src/gauntlet_player.nim

# Run image.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/board-gauntlet
COPY --from=build /workspace/board-gauntlet/board-gauntlet /bin/board-gauntlet
COPY --from=build /workspace/board-gauntlet/board-gauntlet-player /bin/board-gauntlet-player
COPY --from=build /workspace/board-gauntlet/data ./data
COPY --from=build /workspace/board-gauntlet/client ./client

CMD ["/bin/board-gauntlet"]
