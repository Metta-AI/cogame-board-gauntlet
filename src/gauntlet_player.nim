## Board Gauntlet player: prompt, scripted baseline, or external Jev policy.
##
## Prompt players deliver PLAYER_PROMPT and wait for the game to decide.
## PLAYER_JEV=1 selects a player-side System One policy over legal moves.
##
## PLAYER_SCRIPTED=tactician|hustler registers the seat as a scripted
## baseline instead: the server plays it deterministically, no LLM. `1`,
## `true` and `yes` are accepted synonyms for `tactician`.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <image> --name my-gauntlet \
##     --run /bin/board-gauntlet-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  gauntlet/jev_policy,
  whisky

const DefaultPrompt = """
Play to win, one move at a time. Every ply, name the opponent's strongest
threat and your fastest win, then play the legal move that best serves
both. Copy your move exactly from the legal-move list you are given, and
reply with only the JSON object.
"""

const ScriptedNames = ["tactician", "hustler"]

proc scriptedSetting(): string =
  let raw = getEnv("PLAYER_SCRIPTED").strip().toLowerAscii()
  if raw.len == 0:
    return ""
  if raw in ScriptedNames:
    return raw
  if raw in ["1", "true", "yes"]:
    return "tactician"
  ""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt.strip()
  let scripted = scriptedSetting()
  let jev = getEnv("PLAYER_JEV").strip().toLowerAscii() in
    ["1", "true", "yes"]
  if jev and scripted.len > 0:
    quit("PLAYER_JEV and PLAYER_SCRIPTED cannot both be set", 1)

  proc promptFrame(): string =
    if scripted.len > 0:
      $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}
    else:
      $ %*{"type": "prompt", "prompt": prompt, "scripted": false}

  echo "board-gauntlet player: connecting to game"
  let socket = newWebSocket(url)
  if jev:
    socket.send($ %*{"type": "register", "control": "external"})
    echo "board-gauntlet player: Jev external policy registered"
  else:
    socket.send(promptFrame())
    echo "board-gauntlet player: prompt delivered (", prompt.len, " chars",
      (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky RAISES on a close frame, so a receive loop that does not catch
  ## exits 1 and fails hosted certification intermittently (raid 0.1.3).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "board-gauntlet player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "board-gauntlet player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " playing ", payload{"game"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first
          ## send raced the server's slot registration.
          if jev:
            socket.send($ %*{"type": "register", "control": "external"})
          else:
            socket.send(promptFrame())
        of "observation":
          if jev:
            let move = chooseMove(payload["observation"], prompt)
            socket.send($ %*{
              "type": "action", "id": payload["id"], "move": move})
        of "final":
          echo "board-gauntlet player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "board-gauntlet player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "board-gauntlet player: socket closed (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
