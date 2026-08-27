## Board Gauntlet entrypoint: reads the Coworld runtime contract and starts
## either a live episode server or a replay viewer server.

import
  std/[os, times],
  bitworld/runtime,
  gauntlet/server,
  gauntlet/sim

proc drawSeed(): int =
  ## An unpinned seed is drawn ONCE, here, before initSim, and written into
  ## the config. Without it the manifest's "omit for a fresh seed" would
  ## silently mean "always seed 0" and the rotation would always pick
  ## connect-four.
  let raw = int(epochTime() * 1000) xor getCurrentProcessId()
  max(1, abs(raw) mod 1_000_000_000)

when isMainModule:
  let runtimeConfig = readRuntimeConfig()

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    var config = defaultGameConfig()
    config.update(runtimeConfig.config)
    if config.seed == 0:
      config.seed = drawSeed()
      echo "board-gauntlet: seed not pinned; drew ", config.seed
    ## Resolve the rotation AFTER the seed is settled, so a pinned seed
    ## reproduces the episode exactly.
    config = sampleEpisode(config)
    echo "board-gauntlet: seats=", config.players.len,
      " game=", config.game,
      (if config.rotated: " (drawn by the gauntlet rotation)" else: ""),
      " size=", config.size,
      " walls=", config.walls,
      " maxPlies=", config.maxPlies,
      " seed=", config.seed,
      " model=", config.model
    runGameServer(config, runtimeConfig)
