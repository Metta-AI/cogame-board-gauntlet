// Board Gauntlet broadcast chrome.
//
// THIS FILE IS THE CHROME HALF OF cogame-babel's client/renderer.js
// (commit d55d999), copied BYTE FOR BYTE out of the starter file as these
// contiguous regions, in this order:
//
//   COPIED-REGION 23         COLORS (the Ink & Print seat palette)
//   COPIED-REGION 85-87      seatColor
//   COPIED-REGION 101-124    ellipsize, hexToRgb, shade, rgba
//   COPIED-REGION 680-733    ---- Names ----: isBaselineFiller, makeNameMap,
//                            applyNames, clampName
//   COPIED-REGION 735-744    ---- Event feed ----, roundBase
//   COPIED-REGION 790-863    blockHead, renderFeed, escapeHtml
//   COPIED-REGION 963-970    reasonLine
//   COPIED-REGION 972-1027   updateEndscreen
//   COPIED-REGION 1029-1048  bindFeedToggle
//   COPIED-REGION 1142-1222  the scrubber comment and buildScrub
//
// Exactly seven copied lines/regions are edited and each edit is marked in
// place as `BOARD-GAUNTLET EDIT n` with the starter line numbers it
// replaces. Everything else is copied bytes, or is APPENDED at the end of
// the file under "BOARD-GAUNTLET additions to the inherited cogame-babel
// chrome". Nothing is renamed in place.
//
// The game-specific half of the starter renderer (palette, geometry, scene
// drawing, spellTokens, describeEvent, endText, makeEffects, phaseText,
// matchHeader, updateScorebug, stateToView, attachLive, attachReplay and
// the window.BabelRenderer export) is NOT copied: its replacement is
// client/renderer.js, the game block, which declares no identifier this
// file exports.
(function () {
  "use strict";

  // BOARD-GAUNTLET: the two injection slots the copied regions call into
  // (chrome edits 2 and 5), declared here so the copied code below needs no
  // further change. The game block fills them with setFeedText /
  // setEndColumns before it renders anything.
  var feedText = function (event) {
    return String((event && event.kind) || "");
  };
  var endColumns = function () {
    return { heads: [], cell: function () { return ""; } };
  };
  var beatNames = null;

  // ---- COPIED-REGION 23 (cogame-babel client/renderer.js @ d55d999)
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];

  // ---- COPIED-REGION 85-87 (cogame-babel client/renderer.js @ d55d999)
  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  // ---- COPIED-REGION 101-124 (cogame-babel client/renderer.js @ d55d999)
  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the shape rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  // ---- COPIED-REGION 680-733 (cogame-babel client/renderer.js @ d55d999)
  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  // The map also carries the canonical alphabet so feed lines can spell
  // messages the way the stage does.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames, glyphs) {
    var table = tableNames || [];
    var alphabet = glyphs || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      },
      glyph: function (t) {
        return alphabet[t] !== undefined ? alphabet[t] : "?";
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- COPIED-REGION 735-744 (cogame-babel client/renderer.js @ d55d999)
  // ---- Event feed ----------------------------------------------------------

  // Round numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first round event.
  function roundBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "round") return events[i].round === 1 ? 1 : 0;
    }
    return 0;
  }

  // ---- COPIED-REGION 790-863 (cogame-babel client/renderer.js @ d55d999)
  function blockHead(block) {
    // BOARD-GAUNTLET EDIT 1 (starter line 791): a block is one PLY.
    return block < 0 ? "SETUP" : "PLY " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var base = roundBase(events);
    var html = "";
    var lastBlock = null;
    var ctx = { pairs: null, successes: 0, pairRounds: 0 };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      if (event.kind === "round") ctx.pairs = event.pairs || [];
      if (event.kind === "pick") {
        ctx.pairRounds += 1;
        if (event.correct) ctx.successes += 1;
      }
      var scored = event.kind === "pick" && event.correct;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "speak" ? " seat" + (event.seat % COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (scored ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        // BOARD-GAUNTLET EDIT 2 (starter line 827): the game block
        // injects its own line writer with GauntletChrome.setFeedText.
        escapeHtml(feedText(event, nameMap, ctx)) + "</div>";
      // BOARD-GAUNTLET EDIT 3 (starter lines 829-836): the starter's
      // speak/pick notes sub-line becomes this game's `say` sub-line.
      // `say` is SPECTATOR-FACING ONLY and is never shown to the opponent.
      if (event.kind === "move" && event.say &&
          event.say !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.say;
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + ": \u201C" +
            nameMap.text(event.say) + "\u201D") + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- COPIED-REGION 963-970 (cogame-babel client/renderer.js @ d55d999)
  function reasonLine(results) {
    switch (results.reason) {
      // BOARD-GAUNTLET EDIT 6 (starter lines 966-967): rounds -> plies.
      case "deadline":
        return "episode deadline: scored on " + (results.plies || 0) +
          " of " + (results.maxPlies || results.plies || 0) + " plies";
      default: return "";
    }
  }

  // ---- COPIED-REGION 972-1027 (cogame-babel client/renderer.js @ d55d999)
  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var correct = results.correct || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (correct[b] || 0) - (correct[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    // BOARD-GAUNTLET EDIT 7 (starter lines 994-999): two seats and a
    // zero-sum result, so one of them WINS or the game is DRAWN -- nobody
    // "leads the table" -- and the title counts the PLIES this game's
    // results actually carry rather than the starter's rounds.
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(clampName(names[topIndex])).toUpperCase() + " WINS" :
      "DRAWN";
    var reason = reasonLine(results);
    var plies = results.plies || 0;
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + plies +
      (plies === 1 ? " PLY" : " PLIES") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>';
    // BOARD-GAUNTLET EDIT 5a (starter lines 1004-1008): the starter's
    // hard-coded column heads become the injected endColumns(results).
    var columns = endColumns(results);
    columns.heads.forEach(function (head) {
      html += '<span class="end-head">' + escapeHtml(head) + "</span>";
    });
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>";
      // BOARD-GAUNTLET EDIT 5b (starter lines 1020-1023): the starter's
      // four fixed cells become the injected endColumns(results).cell(i, c).
      columns.heads.forEach(function (head, column) {
        html += cell(escapeHtml(String(columns.cell(i, column))));
      });
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  // ---- COPIED-REGION 1029-1048 (cogame-babel client/renderer.js @ d55d999)
  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- COPIED-REGION 1142-1222 (cogame-babel client/renderer.js @ d55d999)
  // Scrubber: a click/drag-to-seek track with one span per round, a marker
  // per pick (coloured by the listener on success, a neutral ghost on
  // failure) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = roundBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    // BOARD-GAUNTLET EDIT 4 (starter lines 1179-1189): the starter's
    // marker <div> loop becomes markPlyBeat() for EVERY recorded event, so
    // every beat is a labelled, clickable button that seeks.
    events.forEach(function (event, i) {
      markPlyBeat(container, event, i, events.length, onSeek);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }


  // ========================================================================
  // BOARD-GAUNTLET additions to the inherited cogame-babel chrome
  // ========================================================================

  // relayout(): measure the transport band ONCE and publish it, plus the
  // HUD scale, on :root. Every consumer reads var(--band) / var(--hudscale)
  // instead of measuring for itself, which is what keeps the endcard out of
  // the transport band and the scorebug legible at 360 px.
  function relayout() {
    var root = document.documentElement;
    var transport = document.getElementById("transport");
    var band = 0;
    if (transport) {
      band = Math.round(transport.getBoundingClientRect().height);
    }
    root.style.setProperty("--band", band + "px");
    var scale = Math.max(0.72, Math.min(window.innerWidth / 1280, 1));
    root.style.setProperty("--hudscale", String(scale));
  }

  // setBeatNames(): the scrub beats are built inside buildScrub, which is
  // copied bytes and takes no name map, so the game block hands one over
  // here before it builds the scrubber. Spectator side only.
  function setBeatNames(nameMap) {
    beatNames = nameMap;
  }

  function beatSeatName(seat) {
    if (typeof seat !== "number" || seat < 0) return "";
    if (beatNames) return clampName(beatNames.seat(seat));
    return "Seat " + seat;
  }

  function beatLabel(event, index) {
    var ply = "Ply " + ((typeof event.round === "number" ?
      event.round : index) + 1);
    switch (event.kind) {
      case "start":
        return "Setup";
      case "move":
        return ply + " \u2014 " + beatSeatName(event.seat) + " plays " +
          (event.move || "") +
          (event.capture ? ", takes " + event.capture : "");
      case "win":
        return ply + " \u2014 " + beatSeatName(event.seat) + " wins (" +
          (event.how || "") + ")";
      case "end":
        return "Final \u2014 " + (event.reason || "") +
          (event.ending ? " / " + event.ending : "");
      default:
        return ply;
    }
  }

  // markPlyBeat(): one CLICKABLE, LABELLED button per recorded event.
  // Every kind the sim can emit has a CSS rule in chrome.css, plus the
  // .capture / .wall modifiers and the seat tints.
  function markPlyBeat(container, event, index, total, onSeek) {
    var kind = event.kind || "";
    var button = document.createElement("button");
    button.type = "button";
    var cls = "beat-marker beat-" + kind;
    if ((kind === "move" || kind === "win") &&
        typeof event.seat === "number" && event.seat >= 0) {
      cls += " seat" + (event.seat % COLORS.length);
    }
    if (kind === "move" && event.capture) cls += " capture";
    if (kind === "move" && event.mkind === "wall") cls += " wall";
    button.className = cls;
    button.style.left = ((index + 1) / Math.max(total, 1) * 100) + "%";
    var label = beatLabel(event, index);
    button.setAttribute("aria-label", label);
    button.title = label;
    button.onclick = function (evt) {
      evt.stopPropagation();
      if (onSeek) onSeek(index + 1);
    };
    container.appendChild(button);
  }

  // The two injection setters chrome edits 2 and 5 depend on.
  function setFeedText(fn) {
    feedText = fn;
  }

  function setEndColumns(fn) {
    endColumns = fn;
  }

  window.GauntletChrome = {
    ellipsize: ellipsize,
    hexToRgb: hexToRgb,
    shade: shade,
    rgba: rgba,
    seatColor: seatColor,
    isBaselineFiller: isBaselineFiller,
    makeNameMap: makeNameMap,
    applyNames: applyNames,
    clampName: clampName,
    roundBase: roundBase,
    blockHead: blockHead,
    renderFeed: renderFeed,
    escapeHtml: escapeHtml,
    reasonLine: reasonLine,
    updateEndscreen: updateEndscreen,
    bindFeedToggle: bindFeedToggle,
    buildScrub: buildScrub,
    relayout: relayout,
    markPlyBeat: markPlyBeat,
    setBeatNames: setBeatNames,
    setFeedText: setFeedText,
    setEndColumns: setEndColumns
  };

  window.addEventListener("load", relayout);
  window.addEventListener("resize", relayout);
  relayout();
})();
