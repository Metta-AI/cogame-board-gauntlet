## Board Gauntlet static replay viewer, wasm side.
##
## JS hands the raw replay bytes to bg_load_replay; this module parses them
## with the SAME sim code the game server runs, re-derives the per-event
## board states, and exposes the enriched payload (identical shape to the
## game's /replay websocket message) for the shared renderer to draw.

import
  std/json,
  gauntlet/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc bgLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "bg_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    let node = replay["config"]
    var config = defaultGameConfig()
    config.game = parseGame(node{"game"}.getStr("connect-four"))
    config.rotated = node{"rotated"}.getBool(false)
    config.size = node{"size"}.getInt(7)
    config.walls = node{"walls"}.getInt(0)
    config.first = node{"first"}.getInt(0)
    config.seed = node{"seed"}.getInt(0)
    config.maxPlies = node{"maxPlies"}.getInt(80)
    ## The replay carries the episode's resolved game and caps; never
    ## re-fit them. The aliases are re-derived from the seed.
    config.sampled = true
    let policyNames = replay{"policyNames"}
    if policyNames != nil and policyNames.kind == JArray and
        policyNames.len == replay["names"].len:
      for name in policyNames:
        config.players.add(PlayerConfig(name: name.getStr()))
    else:
      for name in replay["names"]:
        config.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for entry in replay["events"]:
      events.add(eventFromJson(entry))
    var states = newJArray()
    for frame in replayMatch(config, events):
      states.add(frame.boardStateJson())
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("gauntlet.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "states": states
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc bgPayloadPointer(): ptr uint8 {.exportc: "bg_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc bgPayloadLength(): cint {.exportc: "bg_payload_len", cdecl.} =
  cint(payload.len)

proc bgErrorPointer(): ptr uint8 {.exportc: "bg_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc bgErrorLength(): cint {.exportc: "bg_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
