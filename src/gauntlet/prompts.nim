## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const PromptBankVersion* = "board-gauntlet-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

const Introductions = [
  "You are $1, a cog playing $2 against one other cog on the Board Gauntlet. You play $3.\n\nThis is a PERFECT-INFORMATION, zero-sum, two-player board game. You are shown the entire position, the entire move history and the entire legal-move set every ply. Nothing about the board is hidden from you and nothing about it is hidden from your opponent; the only thing you cannot see is what they are thinking.\n\n",
  "You are the cog $1, playing $3 against one other cog in $2 on the Board Gauntlet.\n\nThis two-player board game has perfect information and is zero-sum. Every ply shows you the complete position, move history, and set of legal moves. Both players see all board information. Your opponent's thoughts are the only hidden part.\n\n",
  "Board Gauntlet briefing:\n1. You are cog $1, playing $3 in $2 against one other cog.\n2. This is a two-player, zero-sum board game with perfect information.\n3. Each ply shows the whole position, move history, and legal-move set.\n4. Both players see all board information; you cannot see the opponent's thoughts.\n\n",
  "Who are you? Cog $1, playing $3 in $2 on the Board Gauntlet against one other cog.\n\nWhat kind of game is this? A perfect-information, zero-sum board game for two players. What can you see every ply? The entire position, move history, and legal-move set. What is hidden? No board information is hidden from either player; only the opponent's thoughts are hidden from you.\n\n",
  "Every ply reveals the entire position, move history, and legal-move set to you. Both players see all board information; you cannot see what your opponent is thinking.\n\nThis is a perfect-information, zero-sum board game for two players. On the Board Gauntlet you are cog $1, playing $3 in $2 against one other cog.\n\n",
  "Your assignment on the Board Gauntlet: cog $1, side $3, game $2, one opposing cog.\n\nThe two-player board game is zero-sum and has perfect information. At each ply you receive the complete position, full move history, and all legal moves. The board contains no information hidden from either player. Your opponent's thoughts remain unseen.\n\n",
  "Board Gauntlet reference\nIdentity: cog $1. Side: $3. Game: $2. Opponent: one other cog.\nGame class: two-player, zero-sum, perfect-information board game.\nInformation each ply: the entire position, entire move history, and entire legal-move set.\nVisibility: all board information is visible to both players; your opponent's thinking is not visible to you.\n\n"
]

const TurnRules = [
  "- Seats alternate strictly, one move each; there is no pass and no double move.\n- If $1 plies are played with no terminal position, the game is adjudicated on the position heuristic you are shown each ply; the wall clock can stop it the same way.\n\nSCORING: +1 for a win, 0 for a draw, -1 for a loss. Nothing else is scored.\n\n",
  "Take exactly one move on your turn, then your opponent moves. You cannot pass or move twice. If play reaches $1 plies without a terminal position, the displayed position heuristic decides the result. The wall-clock limit can end play with the same adjudication. Only the result earns points: a win is +1, a draw 0, and a loss -1.\n\n",
  "Turn and result rules:\n1. Alternate seats, exactly one move per turn; no passes or double moves.\n2. At $1 plies without a terminal position, adjudicate using the position heuristic shown each ply. The wall-clock limit can trigger the same adjudication.\n3. Score only the result: win +1, draw 0, loss -1.\n\n",
  "How do turns work? Seats strictly alternate one move each, with no passing or double moves. What if no terminal position is reached? After $1 plies, use the position heuristic shown each ply to adjudicate; the wall clock can stop play the same way. What counts toward score? Only winning (+1), drawing (0), or losing (-1).\n\n",
  "Only the result is scored: +1 for winning, 0 for drawing, -1 for losing. If the game is still nonterminal after $1 plies, adjudicate on the position heuristic displayed each ply. A wall-clock stop uses the same adjudication. Play alternates strictly between seats, one move per turn; passing and double moves are forbidden.\n\n",
  "Play briefing: make one move, then yield to the other seat. Neither player may pass or take a double move. Reaching $1 plies without a terminal position invokes adjudication by the position heuristic shown every ply; the wall clock may end the game on that basis too. Your sole score is +1 for a win, 0 for a draw, or -1 for a loss.\n\n",
  "Turn reference: strict alternation; one move per seat; no pass; no double move. Adjudication: after $1 plies without a terminal position, use the position heuristic shown each ply; a wall-clock stop can do the same. Score reference: win +1, draw 0, loss -1; no other scoring.\n\n"
]

proc systemPrompt*(selection: PromptSelection, name, game, colour, rules: string,
    maxPlies: int): string =
  let index = ord(selection.selectedVariant)
  result = Introductions[index] % [name, game, colour]
  result.add("RULES\n" & rules)
  result.add(TurnRules[index] % [$maxPlies])
  result.add("OUTPUT FORMAT: reply with ONLY one JSON object, nothing " &
    "else - no analysis, no explanation, no markdown fences, no text " &
    "before or after the object. Your reply must begin with the " &
    "character { and end with }.")
