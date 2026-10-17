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

const PromptBankVersion* = "board-gauntlet-rules-v1"

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

proc introduction*(selection: PromptSelection, name, game, colour: string): string =
  Introductions[ord(selection.selectedVariant)] % [name, game, colour]
