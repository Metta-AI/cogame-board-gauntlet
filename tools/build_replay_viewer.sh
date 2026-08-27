#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, must end up containing index.html).
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

output_dir="$1"
if [[ "${output_dir}" != /* ]]; then
  echo "output dir must be absolute: ${output_dir}" >&2
  exit 1
fi

export PATH="$HOME/.nimby/nim/bin:$PATH"

if command -v emcc >/dev/null && command -v nim >/dev/null; then
  # Local toolchain: build the wasm module directly.
  (cd "${repo_dir}" && nim c --hints:off -d:emscripten \
    replay-viewer/gauntlet_replay.nim)
else
  # Fall back to the pinned emsdk container.
  image_tag="board-gauntlet-replay-viewer-build:$$"
  docker build --platform linux/amd64 \
    --file "${repo_dir}/Dockerfile.replay-viewer" \
    --tag "${image_tag}" "${repo_dir}"
  container_id="$(docker create "${image_tag}")"
  rm -rf "${repo_dir}/replay-viewer/dist"
  docker cp "${container_id}:/workspace/board-gauntlet/replay-viewer/dist" \
    "${repo_dir}/replay-viewer/dist"
  docker rm "${container_id}" >/dev/null
  docker image rm "${image_tag}" >/dev/null
fi

dist="${repo_dir}/replay-viewer/dist"
test -s "${dist}/gauntlet_replay.wasm"
test -s "${dist}/gauntlet_replay.js"

rm -rf "${output_dir}"
# `coworld build` runs this on a fresh checkout where the parent directory
# does not exist yet, so create the whole path, not just the leaf
# (ecos, 2026-08-23).
mkdir -p "${output_dir}/assets"
cp "${dist}/gauntlet_replay.js" "${dist}/gauntlet_replay.wasm" \
  "${output_dir}/"
cp "${repo_dir}/replay-viewer/index.html" \
  "${repo_dir}/replay-viewer/static_replay.js" \
  "${repo_dir}/client/renderer.js" \
  "${repo_dir}/client/chrome_common.js" \
  "${repo_dir}/client/chrome.css" \
  "${output_dir}/"
for asset in arena_floor.png soldier_red_front.png soldier_blue_front.png \
  board_grain.png wall_plank.png font.ttf; do
  cp "${repo_dir}/data/${asset}" "${output_dir}/assets/"
done

test -f "${output_dir}/index.html"
# The shell must announce loading / ready / error to its host, and the
# renderer must set data-replay-loaded on its FIRST DRAWN FRAME; both are
# what tools/ci/viewer_smoke.mjs waits for.
grep -q 'data-replay' "${output_dir}/static_replay.js"
grep -q 'data-replay-loaded' "${output_dir}/renderer.js"
echo "board-gauntlet replay viewer bundle: ${output_dir}"
