// Board Gauntlet game block.
//
// The chrome half of this renderer is client/chrome_common.js, copied
// byte-for-byte out of cogame-babel's client/renderer.js; this file is the
// game-specific half that replaces the starter's palette, geometry and
// scene drawing. It declares NO identifier exported by GauntletChrome, and
// the scrub-beat builder is `markPlyBeat` and lives in the chrome, never
// here: a game-block `function markBeat` would be hoisted over a chrome
// alias and silently turn every beat into an unlabelled div that never
// seeks (tandem, 2026-08-23). tools/ci/chrome_scope_check.mjs asserts it.
//
// One canvas (#table) draws ONE board, centred and whole, with real
// geometry per game: a slotted Connect Four frame, a chequered
// Breakthrough field, a Hex rhombus with seat-coloured edge pairs, and a
// Quoridor lattice with grooved wall channels. Under the board sits a
// RESERVED say band, two lines high, sized from MaxSayLen at the current
// scale so a full-cap line can never be laid out at a negative coordinate.
//
// It draws state objects and derives nothing:
//   {board_game, rotated, size, walls, board[], hWalls[], vWalls[],
//    pawns[2], wallsLeft[2],
//    seats:[{name, policy, standing, captures, wallsUsed, wallsLeft, score,
//            say, notes, scripted, fellBack, readout} x2],
//    mover, ply, maxPlies, plies, legalCount,
//    lastMove:{seat, move, mkind, capture}, eval, winner, winPath[],
//    phase, gameDone, reason, ending}
(function () {
  "use strict";

  var C = window.GauntletChrome;

  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var HUD_FONT = "'rajdhani', system-ui, sans-serif";
  // The reply schema's cap; the say band reserves room for a full line.
  var MAX_SAY_LEN = 80;
  // Playback dwell, per event kind. A quiet move reads fast; a capture and
  // a verdict need a beat longer.
  var DWELL_MOVE = 700;
  var DWELL_CAPTURE = 1100;
  var DWELL_VERDICT = 1500;

  var GAME_LABEL = {
    "connect-four": "CONNECT FOUR",
    "breakthrough": "BREAKTHROUGH",
    "hex": "HEX",
    "quoridor": "QUORIDOR"
  };

  function gameOf(state) {
    return (state && state.board_game) || "connect-four";
  }

  function boardCols(state) {
    return (state && state.size) || 7;
  }

  function boardRows(state) {
    var size = boardCols(state);
    return gameOf(state) === "connect-four" ? size - 1 : size;
  }

  function occupantAt(state, row, col) {
    var board = (state && state.board) || [];
    return board[row * boardCols(state) + col] || "empty";
  }

  function seatOfOccupant(value) {
    if (value === "seat0") return 0;
    if (value === "seat1") return 1;
    return -1;
  }

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["arena_floor.png", "board_grain.png", "wall_plank.png",
      "soldier_red_front.png", "soldier_blue_front.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  // ---- Layout --------------------------------------------------------------

  function layoutOf(w, h, state) {
    var cols = boardCols(state);
    var rows = boardRows(state);
    var scale = Math.max(0.6, Math.min(w / 1280, 1));
    var lineH = Math.max(11, Math.round(15 * scale));
    // The say band is RESERVED whether or not a seat has spoken: `say`
    // arrives without warning and a band that appears late reflows the
    // board mid-playback.
    var sayBand = lineH * 2 + Math.round(12 * scale);
    var pad = Math.max(14, Math.round(22 * scale));
    var availW = Math.max(40, w - pad * 2);
    var availH = Math.max(40, h - sayBand - pad * 2);
    // Hex shears each rank half a cell to the right, so the rhombus is
    // wider than its file count.
    var isHex = gameOf(state) === "hex";
    var spanCols = isHex ? cols + (rows - 1) * 0.5 : cols;
    var cell = Math.min(availW / spanCols, availH / rows);
    var boardW = cell * spanCols;
    var boardH = cell * rows;
    return {
      hex: isHex,
      cols: cols,
      rows: rows,
      cell: cell,
      scale: scale,
      lineH: lineH,
      sayTop: h - sayBand,
      sayBand: sayBand,
      ox: (w - boardW) / 2,
      oy: pad + (availH - boardH) / 2,
      w: w,
      h: h,
      boardW: boardW,
      boardH: boardH
    };
  }

  function cellX(layout, row, col) {
    var shear = 0;
    if (layout.hex) shear = row * layout.cell * 0.5;
    return layout.ox + shear + col * layout.cell;
  }

  function cellY(layout, row) {
    return layout.oy + (layout.rows - 1 - row) * layout.cell;
  }

  // ---- Board surface -------------------------------------------------------

  function drawSurface(ctx, w, h, images, layout) {
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);
    // The printed-board paper grain every game shares.
    var grain = images["board_grain.png"];
    var m = layout.cell * 0.35;
    ctx.save();
    if (grain && grain.width) {
      ctx.fillStyle = ctx.createPattern(grain, "repeat");
      ctx.globalAlpha = 0.5;
    } else {
      ctx.fillStyle = "rgba(242, 232, 216, 0.05)";
    }
    roundRect(ctx, layout.ox - m, layout.oy - m, layout.boardW + m * 2,
      layout.boardH + m * 2, layout.cell * 0.2);
    ctx.fill();
    ctx.restore();
  }

  // ---- Edge labels ---------------------------------------------------------

  function drawLabels(ctx, layout, state) {
    var size = Math.max(8, Math.round(layout.cell * 0.28));
    // At 360 px there is no room for every file; label every other one.
    var stride = layout.w < 640 ? 2 : 1;
    ctx.save();
    ctx.font = "600 " + size + "px " + HUD_FONT;
    ctx.fillStyle = GHOST;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (var col = 0; col < layout.cols; col += stride) {
      var x = cellX(layout, 0, col) + layout.cell / 2;
      var y = cellY(layout, 0) + layout.cell + size * 0.3;
      if (y + size < layout.sayTop) {
        ctx.fillText(String.fromCharCode(97 + col), x, y);
      }
    }
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    for (var row = 0; row < layout.rows; row += stride) {
      var lx = cellX(layout, row, 0) - size * 0.35;
      var ly = cellY(layout, row) + layout.cell / 2;
      if (lx - size > 0) ctx.fillText(String(row + 1), lx, ly);
    }
    ctx.restore();
  }

  // ---- Connect Four --------------------------------------------------------

  function drawConnectFour(ctx, layout, state, wins) {
    var r = layout.cell * 0.38;
    ctx.save();
    ctx.fillStyle = "rgba(63, 124, 196, 0.22)";
    ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
    ctx.lineWidth = Math.max(1, layout.cell * 0.05);
    roundRect(ctx, layout.ox, layout.oy, layout.boardW, layout.boardH,
      layout.cell * 0.18);
    ctx.fill();
    ctx.stroke();
    for (var row = 0; row < layout.rows; row++) {
      for (var col = 0; col < layout.cols; col++) {
        var cx = cellX(layout, row, col) + layout.cell / 2;
        var cy = cellY(layout, row) + layout.cell / 2;
        var seat = seatOfOccupant(occupantAt(state, row, col));
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        if (seat < 0) {
          ctx.fillStyle = "rgba(12, 8, 5, 0.72)";
          ctx.fill();
          ctx.strokeStyle = "rgba(242, 232, 216, 0.10)";
          ctx.lineWidth = 1;
          ctx.stroke();
        } else {
          var hex = seat === 0 ? COLOR_HEX.red : COLOR_HEX.blue;
          ctx.fillStyle = hex;
          ctx.fill();
          ctx.strokeStyle = C.shade(hex, 0.6);
          ctx.lineWidth = Math.max(1, layout.cell * 0.06);
          ctx.stroke();
          ctx.beginPath();
          ctx.arc(cx - r * 0.3, cy - r * 0.3, r * 0.22, 0, Math.PI * 2);
          ctx.fillStyle = "rgba(242, 232, 216, 0.3)";
          ctx.fill();
        }
        if (wins[row * layout.cols + col]) {
          ctx.beginPath();
          ctx.arc(cx, cy, r * 1.16, 0, Math.PI * 2);
          ctx.strokeStyle = AMBER;
          ctx.lineWidth = Math.max(2, layout.cell * 0.09);
          ctx.stroke();
        }
      }
    }
    ctx.restore();
  }

  // ---- Breakthrough --------------------------------------------------------

  function drawBreakthrough(ctx, layout, state, wins) {
    ctx.save();
    for (var row = 0; row < layout.rows; row++) {
      for (var col = 0; col < layout.cols; col++) {
        var x = cellX(layout, row, col);
        var y = cellY(layout, row);
        ctx.fillStyle = (row + col) % 2 === 0 ?
          "rgba(242, 232, 216, 0.10)" : "rgba(242, 232, 216, 0.03)";
        ctx.fillRect(x, y, layout.cell, layout.cell);
        var seat = seatOfOccupant(occupantAt(state, row, col));
        if (seat >= 0) {
          var hex = seat === 0 ? COLOR_HEX.red : COLOR_HEX.blue;
          var cx = x + layout.cell / 2;
          var cy = y + layout.cell / 2;
          var pr = layout.cell * 0.32;
          ctx.beginPath();
          ctx.ellipse(cx, cy + pr * 0.5, pr, pr * 0.45, 0, 0, Math.PI * 2);
          ctx.fillStyle = "rgba(12, 8, 5, 0.45)";
          ctx.fill();
          ctx.beginPath();
          ctx.arc(cx, cy, pr, 0, Math.PI * 2);
          ctx.fillStyle = hex;
          ctx.fill();
          ctx.strokeStyle = C.shade(hex, 0.55);
          ctx.lineWidth = Math.max(1, layout.cell * 0.06);
          ctx.stroke();
        }
        if (wins[row * layout.cols + col]) {
          ctx.strokeStyle = AMBER;
          ctx.lineWidth = Math.max(2, layout.cell * 0.09);
          ctx.strokeRect(x + 1, y + 1, layout.cell - 2, layout.cell - 2);
        }
      }
    }
    ctx.strokeStyle = "rgba(242, 232, 216, 0.28)";
    ctx.lineWidth = 1;
    ctx.strokeRect(layout.ox, layout.oy, layout.boardW, layout.boardH);
    // The capture that just happened flashes on the emptied cell.
    var last = state.lastMove || {};
    if (last.capture) {
      var col2 = last.capture.charCodeAt(0) - 97;
      var row2 = parseInt(last.capture.slice(1), 10) - 1;
      if (col2 >= 0 && row2 >= 0) {
        var fx = cellX(layout, row2, col2);
        var fy = cellY(layout, row2);
        ctx.strokeStyle = AMBER;
        ctx.lineWidth = Math.max(2, layout.cell * 0.08);
        ctx.beginPath();
        ctx.moveTo(fx + layout.cell * 0.25, fy + layout.cell * 0.25);
        ctx.lineTo(fx + layout.cell * 0.75, fy + layout.cell * 0.75);
        ctx.moveTo(fx + layout.cell * 0.75, fy + layout.cell * 0.25);
        ctx.lineTo(fx + layout.cell * 0.25, fy + layout.cell * 0.75);
        ctx.stroke();
      }
    }
    ctx.restore();
  }

  // ---- Hex -----------------------------------------------------------------

  function hexPath(ctx, cx, cy, r) {
    ctx.beginPath();
    for (var i = 0; i < 6; i++) {
      var a = Math.PI / 180 * (60 * i - 30);
      var px = cx + Math.cos(a) * r;
      var py = cy + Math.sin(a) * r;
      if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.closePath();
  }

  function drawHex(ctx, layout, state, wins) {
    var r = layout.cell * 0.56;
    ctx.save();
    // Seat-coloured edge pairs, painted along the borders each seat owns:
    // red links file a to the last file, blue links rank 1 to the top rank.
    for (var row = 0; row < layout.rows; row++) {
      for (var col = 0; col < layout.cols; col++) {
        var cx = cellX(layout, row, col) + layout.cell / 2;
        var cy = cellY(layout, row) + layout.cell / 2;
        hexPath(ctx, cx, cy, r);
        var seat = seatOfOccupant(occupantAt(state, row, col));
        if (seat < 0) {
          ctx.fillStyle = "rgba(242, 232, 216, 0.07)";
        } else {
          ctx.fillStyle = seat === 0 ? COLOR_HEX.red : COLOR_HEX.blue;
        }
        ctx.fill();
        var edge = "rgba(242, 232, 216, 0.2)";
        var width = 1;
        if (col === 0 || col === layout.cols - 1) {
          edge = C.rgba(COLOR_HEX.red, 0.85);
          width = Math.max(2, layout.cell * 0.07);
        }
        if (row === 0 || row === layout.rows - 1) {
          edge = C.rgba(COLOR_HEX.blue, 0.85);
          width = Math.max(2, layout.cell * 0.07);
        }
        ctx.strokeStyle = edge;
        ctx.lineWidth = width;
        ctx.stroke();
        if (wins[row * layout.cols + col]) {
          hexPath(ctx, cx, cy, r * 0.72);
          ctx.strokeStyle = AMBER;
          ctx.lineWidth = Math.max(2, layout.cell * 0.08);
          ctx.stroke();
        }
      }
    }
    ctx.restore();
  }

  // ---- Quoridor ------------------------------------------------------------

  function drawQuoridor(ctx, layout, state, images, wins) {
    var groove = Math.max(2, layout.cell * 0.16);
    var tile = layout.cell - groove;
    ctx.save();
    for (var row = 0; row < layout.rows; row++) {
      for (var col = 0; col < layout.cols; col++) {
        var x = cellX(layout, row, col) + groove / 2;
        var y = cellY(layout, row) + groove / 2;
        ctx.fillStyle = "rgba(242, 232, 216, 0.08)";
        roundRect(ctx, x, y, tile, tile, tile * 0.12);
        ctx.fill();
        if (wins[row * layout.cols + col]) {
          ctx.strokeStyle = AMBER;
          ctx.lineWidth = Math.max(2, layout.cell * 0.08);
          ctx.stroke();
        }
      }
    }
    // Goal ranks, tinted in the seat that is racing to them.
    ctx.fillStyle = C.rgba(COLOR_HEX.red, 0.16);
    ctx.fillRect(layout.ox, cellY(layout, layout.rows - 1), layout.boardW,
      layout.cell);
    ctx.fillStyle = C.rgba(COLOR_HEX.blue, 0.16);
    ctx.fillRect(layout.ox, cellY(layout, 0), layout.boardW, layout.cell);

    var anchors = layout.cols - 1;
    var plank = images["wall_plank.png"];
    function drawPlank(x, y, w, h) {
      if (plank && plank.width) {
        ctx.drawImage(plank, x, y, w, h);
      } else {
        ctx.fillStyle = "#c8a978";
        roundRect(ctx, x, y, w, h, Math.min(w, h) * 0.35);
        ctx.fill();
      }
      ctx.strokeStyle = "rgba(42, 31, 22, 0.8)";
      ctx.lineWidth = 1;
      roundRect(ctx, x, y, w, h, Math.min(w, h) * 0.35);
      ctx.stroke();
    }
    var hWalls = state.hWalls || [];
    var vWalls = state.vWalls || [];
    for (var a = 0; a < anchors; a++) {
      for (var b = 0; b < anchors; b++) {
        var index = a * anchors + b;
        if (hWalls[index]) {
          drawPlank(cellX(layout, a, b) + groove / 2,
            cellY(layout, a) - groove / 2,
            layout.cell * 2 - groove, groove);
        }
        if (vWalls[index]) {
          drawPlank(cellX(layout, a, b) + layout.cell - groove / 2,
            cellY(layout, a + 1) + groove / 2,
            groove, layout.cell * 2 - groove);
        }
      }
    }
    var pawns = state.pawns || [];
    for (var seat = 0; seat < 2; seat++) {
      var cell = pawns[seat];
      if (typeof cell !== "number" || cell < 0) continue;
      var prow = Math.floor(cell / layout.cols);
      var pcol = cell % layout.cols;
      var pcx = cellX(layout, prow, pcol) + layout.cell / 2;
      var pcy = cellY(layout, prow) + layout.cell / 2;
      var hex = seat === 0 ? COLOR_HEX.red : COLOR_HEX.blue;
      ctx.beginPath();
      ctx.arc(pcx, pcy, layout.cell * 0.3, 0, Math.PI * 2);
      ctx.fillStyle = hex;
      ctx.fill();
      ctx.strokeStyle = C.shade(hex, 0.55);
      ctx.lineWidth = Math.max(1, layout.cell * 0.07);
      ctx.stroke();
    }
    ctx.restore();
  }

  // ---- The say band --------------------------------------------------------

  function drawSayBand(ctx, layout, state) {
    var seats = state.seats || [];
    var size = Math.max(10, Math.round(layout.lineH * 0.78));
    ctx.save();
    ctx.font = size + "px " + HUD_FONT;
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    var pad = Math.max(8, Math.round(10 * layout.scale));
    // The band is measured from the CAP, not from the current text, so a
    // full 80-rune line is always laid out at the same positive baseline.
    var width = Math.max(40, layout.w - pad * 2);
    for (var seat = 0; seat < 2; seat++) {
      var info = seats[seat] || {};
      var y = layout.sayTop + layout.lineH * (seat + 0.5) +
        Math.round(6 * layout.scale);
      var text = String(info.say || "").slice(0, MAX_SAY_LEN);
      ctx.fillStyle = seat === 0 ? COLOR_HEX.red : COLOR_HEX.blue;
      if (!text) {
        ctx.fillStyle = "rgba(138, 127, 114, 0.55)";
        text = C.clampName(info.name || ("Seat " + seat)) + " \u2014 \u00B7 \u00B7 \u00B7";
      } else {
        text = C.clampName(info.name || ("Seat " + seat)) + ": \u201C" +
          text + "\u201D";
      }
      ctx.fillText(C.ellipsize(ctx, text, width), pad, y);
    }
    ctx.restore();
  }

  // ---- The frame -----------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var state = view.state || {};
    var layout = layoutOf(w, h, state);
    drawSurface(ctx, w, h, images, layout);
    var wins = {};
    (state.winPath || []).forEach(function (name) {
      var col = name.charCodeAt(0) - 97;
      var row = parseInt(name.slice(1), 10) - 1;
      if (col >= 0 && row >= 0) wins[row * layout.cols + col] = true;
    });
    var game = gameOf(state);
    if (game === "connect-four") {
      drawConnectFour(ctx, layout, state, wins);
    } else if (game === "breakthrough") {
      drawBreakthrough(ctx, layout, state, wins);
    } else if (game === "hex") {
      drawHex(ctx, layout, state, wins);
    } else {
      drawQuoridor(ctx, layout, state, images, wins);
    }
    drawLabels(ctx, layout, state);
    drawSayBand(ctx, layout, state);
  }

  // ---- Feed lines ----------------------------------------------------------

  function moveWords(event, ctx) {
    var move = event.move || "";
    if (event.mkind === "drop") {
      // The feed replays the whole event list in order, so the column
      // heights can be counted as they go and the disc named where it
      // actually lands: "drops into d - lands on d3", never an index.
      if (!ctx.heights) ctx.heights = {};
      var rank = (ctx.heights[move] || 0) + 1;
      ctx.heights[move] = rank;
      return "drops into " + move + " \u2014 lands on " + move + rank;
    }
    if (event.mkind === "wall") {
      return "wall at " + move.slice(0, move.length - 1) + " (" +
        (move.slice(-1) === "h" ? "horizontal" : "vertical") + ")";
    }
    if (event.mkind === "capture") {
      var parts = move.split("-");
      return parts[0] + " takes " + parts[1];
    }
    if (event.mkind === "jump") {
      return "pawn jumps to " + move;
    }
    if (event.mkind === "step") {
      if (move.indexOf("-") > 0) {
        return move.split("-")[0] + " to " + move.split("-")[1];
      }
      return "pawn to " + move;
    }
    return "plays " + move;
  }

  function winWords(event) {
    var path = event.path || [];
    switch (event.how) {
      case "line":
        return "lines up " + path.join("-");
      case "connection":
        return "connects " + (path.length ?
          path[path.length - 1] + "\u2013" + path[0] : "its edges");
      case "home-rank":
        return "breaks through on " + (path[0] || "");
      case "no-pieces":
        return "takes the last piece";
      case "goal-row":
        return "reaches " + (path[0] || "its goal rank");
      case "no-moves":
        return "wins: the opponent has no legal move";
      default:
        return "wins";
    }
  }

  function endWords(event) {
    var ending = event.ending || "";
    var reason = event.reason || "";
    var words = {
      "line": "four in a row",
      "board-full": "board full \u2014 drawn",
      "home-rank": "a piece reached the far home rank",
      "no-pieces": "the last enemy piece was taken",
      "no-moves": "the seat to move had no legal move",
      "connection": "the edges were linked",
      "goal-row": "a pawn reached its goal rank",
      "ply-cap": "ply cap, adjudicated on position",
      "wall-clock": "stopped on the clock, adjudicated on position"
    };
    return reason + " \u2014 " + (words[ending] || ending);
  }

  // The chrome's renderFeed calls this for every event (chrome edit 2).
  function feedLine(event, nameMap, ctx) {
    var name = function (seat) { return C.clampName(nameMap.seat(seat)); };
    switch (event.kind) {
      case "start":
        return "Board set \u2014 two cogs, one board, nothing hidden.";
      case "move":
        return name(event.seat) + " " + moveWords(event, ctx) +
          (event.fellBack ? " (fell back)" : "");
      case "win":
        return name(event.seat) + " " + winWords(event);
      case "end":
        return endWords(event);
      default:
        return String(event.kind || "");
    }
  }

  // The chrome's updateEndscreen calls this for its columns (chrome edit 5).
  function endTable(results) {
    var walls = (results && results.game === "quoridor");
    var heads = ["score", "standing", walls ? "walls used" : "captures",
      "fallbacks"];
    return {
      heads: heads,
      cell: function (seat, column) {
        switch (column) {
          case 0: return ((results.scores || [])[seat] || 0).toFixed(0);
          case 1: return (results.standing || [])[seat] || 0;
          case 2: return walls ? ((results.wallsUsed || [])[seat] || 0) :
            ((results.captures || [])[seat] || 0);
          default: return (results.fallbacks || [])[seat] || 0;
        }
      }
    };
  }

  // ---- Clock and scorebug --------------------------------------------------

  function headerText(state, nameMap) {
    if (!state) return "";
    var parts = [];
    var label = GAME_LABEL[gameOf(state)] || "BOARD";
    var size = boardCols(state) + "\u00D7" + boardRows(state);
    // The rotation arrow appears ONLY when the episode was drawn.
    var head = (state.rotated ? "GAUNTLET \u2192 " : "") + label;
    // Under 640 px the size word is the first thing to go.
    if (window.innerWidth >= 640) head += " " + size;
    parts.push(head);
    parts.push("PLY " + (state.plies || 0) + " / " + (state.maxPlies || 0));
    if (state.gameDone) {
      parts.push("FINAL");
    } else if (typeof state.mover === "number" && nameMap) {
      parts.push(C.clampName(nameMap.seat(state.mover)).toUpperCase() +
        " TO MOVE");
    }
    return parts.join(" \u00B7 ");
  }

  function scorebugHtml(state, nameMap, assetBase) {
    var seats = state.seats || [];
    var html = "";
    seats.forEach(function (seat, index) {
      var colour = index === 0 ? "red" : "blue";
      var sprite = index === 0 ? "soldier_red_front.png" :
        "soldier_blue_front.png";
      var display = nameMap ? nameMap.seat(index) : (seat.policy || seat.name);
      html += '<div class="plate ' + colour +
        (state.gameDone && state.winner === index ? " winner" : "") + '">' +
        '<img class="plate-cog" alt="" src="' +
        assetUrl(assetBase, sprite) + '">' +
        '<span class="plate-name">' +
        C.escapeHtml(C.clampName(display)) +
        '<em class="plate-alias">' + C.escapeHtml(seat.name || "") +
        "</em></span>" +
        (!state.gameDone && state.mover === index ?
          '<span class="plate-it">\u25B6</span>' : "") +
        '<span class="plate-readout">' +
        C.escapeHtml(seat.readout || "") + "</span>" +
        '<span class="plate-score">' + (seat.score > 0 ? "+1" :
          seat.score < 0 ? "\u22121" : "0") + "</span>" +
        '<span class="plate-label">score</span>' +
        "</div>";
    });
    // #evalbar is APPENDED INSIDE the existing #scorebug at runtime; it is
    // never spliced into the starter's markup by hand.
    var value = Math.max(-1, Math.min(Number(state.eval) || 0, 1));
    var pct = Math.abs(value) * 50;
    html += '<div id="evalbar" class="' + (value >= 0 ? "lead0" : "lead1") +
      '" title="position heuristic"><i style="left:' +
      (value >= 0 ? 50 : 50 - pct) + "%;width:" + pct + '%"></i>' +
      '<b>HEURISTIC</b></div>';
    return html;
  }

  function updateBug(container, state, nameMap, assetBase) {
    if (!container || !state) return;
    var html = scorebugHtml(state, nameMap, assetBase);
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // ---- Drivers -------------------------------------------------------------

  function seatNames(state) {
    return (state.seats || []).map(function (seat) { return seat.name; });
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = C.makeNameMap([], null, []);
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              nameMap = C.makeNameMap(seatNames(latest), latest.policyNames,
                []);
              C.setBeatNames(nameMap);
              if (options.feed) {
                C.renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = headerText(latest, nameMap);
              }
              updateBug(options.scorebug, latest, nameMap,
                options.assetBase);
            }
            if (data.type === "final") {
              C.updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          renderer.draw({ state: latest });
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload, onFirstFrame}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var results = payload.results || {};
    var nameMap = C.makeNameMap(payload.names, payload.policyNames, []);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var announced = false;

    C.setBeatNames(nameMap);
    C.setFeedText(feedLine);
    C.setEndColumns(endTable);

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var scrub = C.buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] || {};
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (options.feed) {
          // The feed lines need the state they are describing.
          C.renderFeed(options.feed, events, nameMap, index);
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = headerText(currentState(), nameMap);
        }
        updateBug(options.scorebug, currentState(), nameMap,
          options.assetBase);
        // EVERY seek dismisses the endcard; it only shows at the very end.
        C.updateEndscreen(options.endscreen, results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = DWELL_MOVE;
        if (shown && (shown.kind === "win" || shown.kind === "end")) {
          stepMs = DWELL_VERDICT;
        } else if (shown && shown.kind === "move" && shown.capture) {
          stepMs = DWELL_CAPTURE;
        }
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "\u275A\u275A" : "\u25B6";
          options.playButton.classList.toggle("on", running);
        }
        renderer.draw({ state: currentState() });
        if (!announced) {
          announced = true;
          // The host may only sample this once, so it must mean a PICTURE,
          // not merely a parsed payload: set it from the first DRAWN frame.
          document.documentElement.setAttribute("data-replay-loaded", "true");
          if (options.onFirstFrame) options.onFirstFrame();
        }
        requestAnimationFrame(frame);
      })(0);
    });
  }

  // The feed's ctx carries the state each line is describing.
  var wrappedRenderFeed = function (element, events, nameMap, currentIndex) {
    C.renderFeed(element, events, nameMap, currentIndex);
  };

  window.GauntletRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: wrappedRenderFeed,
    bindFeedToggle: C.bindFeedToggle,
    feedLine: feedLine,
    endTable: endTable,
    headerText: headerText
  };

  C.setFeedText(feedLine);
  C.setEndColumns(endTable);
})();
