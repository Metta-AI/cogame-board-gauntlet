# cogame-board-gauntlet

**A rotating perfect-information ladder: Connect Four, Breakthrough, Hex and
Quoridor, one game drawn per episode, two cogs, zero sum.**

Two cogs, one board, no dice and nothing hidden. Both seats see the whole
position, the whole move history and the whole legal-move set; the only thing
either of them cannot see is what the other one is *thinking*. What varies is
the board itself: an episode plays **one of four classic games**, drawn
deterministically from the episode seed and **announced to both seats before
their first move**. A policy that only knows one opening book scores in one
episode of four.

| `game` | Board | `maxPlies` | Seats |
|---|---|---|---|
| `connect-four` | 7 files × 6 ranks | 42 | 2 |
| `breakthrough` | 6 × 6, 12 pieces a side | 80 | 2 |
| `hex` | 7 × 7 rhombus | 49 | 2 |
| `quoridor` | 9 × 9, 10 walls a side | 80 | 2 |

The rotation order is the fixed list
`["connect-four", "breakthrough", "hex", "quoridor"]`, and the `gauntlet`
variant resolves `game = RotationOrder[((seed mod 4) + 4) mod 4]` before the
first move. If the seed is unpinned the server draws one, echoes it, and
writes it into the config, so **every replay carries a concrete seed and
re-derives exactly**.

## A policy is just a prompt

Every decision is made inside the game server: it composes the acting seat's
whole observation — the resolved game and its rules, the board as a labelled
ASCII diagram, the full move history, both seats' position heuristics and the
complete legal-move set — adds that seat's operator prompt, and asks Claude for
one move. So a new policy is an upload of the same image with a different
prompt:

```bash
coworld upload-policy coworld-board-gauntlet:latest \
  --name my-gauntlet \
  --run /bin/board-gauntlet-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Set **`PLAYER_SCRIPTED=tactician`** or **`PLAYER_SCRIPTED=hustler`** instead to
field one of the two built-in baselines. They also play *every* seat when no
LLM credentials are available, which is what makes offline certification and
the raw-Docker smoke complete.

- **`tactician`** — wins on the spot when it can; otherwise refuses moves that
  hand the opponent an immediate win; otherwise maximises
  `standing(self) − standing(opponent)`; ties go to the lowest canonical move
  index. It is also the fallback every failed LLM decision lands on.
- **`hustler`** — never defends. It maximises its own progress and ignores the
  opponent's, with a per-game pre-filter (centre files in Connect Four, the most
  advanced piece in Breakthrough, its own shortest route in Hex, walls only when
  behind in Quoridor), tie-broken by the *highest* canonical index.

## Scoring

```
score_i = +1  if seat i won
           0  on a draw
          -1  if seat i lost          score_0 + score_1 = 0, always
```

The league ranks by mean episode `score`, higher first. Everything richer —
captures, walls used, the final `standing`, plies, fallbacks — is reported for
the audience and the audit and is deliberately **not** scored, so no policy can
farm the metric instead of winning.

`results.reason` has exactly two legal values, `complete` and `deadline`; the
finer ending rides in `results.ending`, one of `line`, `board-full`,
`home-rank`, `no-pieces`, `no-moves`, `connection`, `goal-row`, `ply-cap` or
`wall-clock`. A `deadline` result is a real result: the position is fully scored
by `standing` at the stop.

The replay viewer draws an **eval bar** from that same `standing` heuristic and
captions it `HEURISTIC`, because it is this repository's own heuristic and not
an engine evaluation. There is no OpenSpiel dependency, no external engine and
no reference bot: every rule is implemented natively in Nim in `src/gauntlet/`.

## Layout

```
gauntlet.nimble
src/gauntlet.nim                     entrypoint -> /bin/board-gauntlet
src/gauntlet_player.nim              player     -> /bin/board-gauntlet-player
src/gauntlet/types.nim               config, events, geometry, rune-safe text
src/gauntlet/sim.nim                 the one dispatch point over the four games
src/gauntlet/games/connect_four.nim  per-game rules
src/gauntlet/games/breakthrough.nim  per-game rules
src/gauntlet/games/hex.nim           per-game rules
src/gauntlet/games/quoridor.nim      per-game rules
src/gauntlet/llm.nim                 Claude client, prompts, the two baselines
src/gauntlet/server.nim              mummy HTTP/WS server, replay writer
client/chrome_common.js              the inherited cogame-babel chrome
client/renderer.js                   the game block: four boards on one canvas
client/chrome.css                    cogame-babel's chrome.css + the game block
replay-viewer/gauntlet_replay.nim    the wasm entry, same sim module
tools/build_replay_viewer.sh         the `coworld build` hook (emscripten)
tools/ci/                            docker smoke, viewer smoke, scope check
scripts/art/                         the nano-banana cog sheet and its split
tests/                               sim, bot, replay and manifest tests
```

## Protocols

`gauntlet.player.v1` over `COWORLD_PLAYER_WS_URL`: `welcome`, a per-ply
redacted `state`, and a `final` frame; the player sends
`{"type":"prompt","prompt":…,"scripted":"tactician"|"hustler"|true|false}` on
connect and again after `welcome`. `/global` sends the whole spectator
snapshot after every event. Moves and cells are **algebraic strings** in every
frame and in the replay bytes (`"d"`, `"c4"`, `"b2-c3"`, `"e3h"`), never
internal indices. Full text in `coworld_manifest_template.json` and in the
`rules.md` documentation page.

## Building and testing

The whole toolchain lives in CI (`.github/workflows/ci.yml`): Nim tests in
both debug and release, a raw-Docker end-to-end episode with the certification
fixture, and a real headless-browser load of the static wasm replay viewer
against the replay that episode produced. Locally:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
# regenerate nim.cfg from your own package tree (the committed one is gitignored)
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg
nim r --path:src tests/test_sim.nim
```

Replays are a **static wasm bundle**, never a pod: `tools/build_replay_viewer.sh`
compiles the same `gauntlet/sim` module to WebAssembly and bundles it with the
renderer, the chrome and the assets, and the browser re-derives every frame from
the recorded events.

## Art

The two seat cogs in the scorebug are nano-banana renders of the Softmax cog,
one kit per role — the red seat holds a disc and a hex stone, the blue seat a
pawn and a wall plank — so the seats read apart at plate scale with the labels
hidden. The source sheet and the split script are committed under
`scripts/art/`; `scripts/art/make_board_textures.py` authors the two board
surfaces (`data/board_grain.png`, `data/wall_plank.png`). `data/arena_floor.png`
and `data/font.ttf` are carried over from `cogame-babel` (MIT; the floor
originates in `coworld-ctf`, the font is Rajdhani — see
`data/FONT_LICENSE.txt`).

MIT licensed.
