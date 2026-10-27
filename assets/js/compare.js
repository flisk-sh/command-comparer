/* Search, filters, theme toggle and copy buttons. The table is plain HTML, so the page
   still reads fine without this script. Storage and clipboard can fail; both are guarded. */
(function () {
  "use strict";

  var root = document.documentElement;
  root.classList.add("js");

  // --- Theme -------------------------------------------------------------
  var themeBtn = document.getElementById("theme-toggle");
  var media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function currentTheme() {
    var set = root.getAttribute("data-theme");
    if (set === "light" || set === "dark") return set;
    return media && media.matches ? "dark" : "light";
  }

  function paintThemeButton() {
    if (!themeBtn) return;
    var next = currentTheme() === "dark" ? "light" : "dark";
    themeBtn.textContent = next === "light" ? "Light mode" : "Dark mode";
    themeBtn.setAttribute("aria-label", "Switch to " + next + " mode");
  }

  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var next = currentTheme() === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem("theme", next); } catch (e) {}
      paintThemeButton();
    });
    if (media && media.addEventListener) media.addEventListener("change", paintThemeButton);
    paintThemeButton();
  }

  // --- Filters -----------------------------------------------------------
  var table = document.getElementById("comparison");
  if (!table) return;

  var rows = Array.prototype.slice.call(table.querySelectorAll("tbody tr"));
  var input = document.getElementById("q");
  var catBox = document.getElementById("cats");
  var toolBox = document.getElementById("tools-toggle");
  var countEl = document.getElementById("count");
  var emptyEl = document.getElementById("empty");

  Array.prototype.forEach.call(document.querySelectorAll(".js-only"), function (el) {
    el.hidden = el.id === "empty" ? el.hidden : false;
  });

  function text(el) { return el ? el.textContent : ""; }

  // Search text per row: the task, its keywords, and each tool's command and note.
  var haystack = rows.map(function (row) {
    var parts = [text(row.querySelector(".cell-task-name")), row.getAttribute("data-keywords") || ""];
    Array.prototype.forEach.call(row.querySelectorAll("td"), function (td) {
      parts.push(td.getAttribute("data-label") || "");
      Array.prototype.forEach.call(td.querySelectorAll("code, .cell-note, .cell-empty"), function (n) {
        parts.push(n.textContent);
      });
    });
    return parts.join(" ").toLowerCase().replace(/\s+/g, " ");
  });

  var state = { q: "", cat: "all", off: {} };

  function readUrl() {
    try {
      var p = new URLSearchParams(window.location.search);
      state.q = (p.get("q") || "").trim();
      var cat = p.get("cat");
      if (cat && catBox && catBox.querySelector('[data-cat="' + cat.replace(/[^\w-]/g, "") + '"]')) state.cat = cat;
      (p.get("hide") || "").split(",").forEach(function (id) {
        if (id && id !== "flisk") state.off[id] = true;
      });
    } catch (e) {}
  }

  function writeUrl() {
    try {
      var p = new URLSearchParams();
      if (state.q) p.set("q", state.q);
      if (state.cat !== "all") p.set("cat", state.cat);
      var hidden = Object.keys(state.off).filter(function (k) { return state.off[k]; });
      if (hidden.length) p.set("hide", hidden.join(","));
      var qs = p.toString();
      history.replaceState(null, "", window.location.pathname + (qs ? "?" + qs : "") + window.location.hash);
    } catch (e) {}
  }

  function apply() {
    var terms = state.q.toLowerCase().split(/\s+/).filter(Boolean);
    var shown = 0;

    rows.forEach(function (row, i) {
      var catOk = state.cat === "all" || row.getAttribute("data-category") === state.cat;
      var hay = haystack[i];
      var textOk = terms.every(function (t) { return hay.indexOf(t) !== -1; });
      var visible = catOk && textOk;
      row.hidden = !visible;
      if (visible) shown += 1;
    });

    Array.prototype.forEach.call(table.querySelectorAll("[data-tool]"), function (cell) {
      cell.hidden = !!state.off[cell.getAttribute("data-tool")];
    });

    if (countEl) countEl.textContent = "Showing " + shown + " of " + rows.length + " tasks";
    if (emptyEl) emptyEl.hidden = shown !== 0;
    table.hidden = shown === 0;
  }

  function paintChips() {
    if (catBox) {
      Array.prototype.forEach.call(catBox.querySelectorAll(".chip"), function (chip) {
        chip.setAttribute("aria-pressed", String(chip.getAttribute("data-cat") === state.cat));
      });
    }
    if (toolBox) {
      Array.prototype.forEach.call(toolBox.querySelectorAll(".chip"), function (chip) {
        chip.setAttribute("aria-pressed", String(!state.off[chip.getAttribute("data-tool")]));
      });
    }
  }

  if (input) {
    input.addEventListener("input", function () {
      state.q = input.value.trim();
      apply();
      writeUrl();
    });
  }

  if (catBox) {
    catBox.addEventListener("click", function (e) {
      var chip = e.target.closest(".chip");
      if (!chip) return;
      state.cat = chip.getAttribute("data-cat");
      paintChips();
      apply();
      writeUrl();
    });
  }

  if (toolBox) {
    toolBox.addEventListener("click", function (e) {
      var chip = e.target.closest(".chip");
      if (!chip || chip.disabled) return;
      var id = chip.getAttribute("data-tool");
      state.off[id] = !state.off[id];
      paintChips();
      apply();
      writeUrl();
    });
  }

  document.addEventListener("keydown", function (e) {
    if (e.key !== "/" || e.metaKey || e.ctrlKey || e.altKey || !input) return;
    var tag = (e.target.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select" || e.target.isContentEditable) return;
    e.preventDefault();
    input.focus();
  });

  readUrl();
  if (input) input.value = state.q;
  paintChips();
  apply();

  // --- Copy buttons --------------------------------------------------------
  function fallbackCopy(value) {
    var ta = document.createElement("textarea");
    ta.value = value;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(ta);
    return ok;
  }

  function flash(btn, label) {
    var old = btn.textContent;
    btn.textContent = label;
    window.setTimeout(function () { btn.textContent = old; }, 1400);
  }

  table.addEventListener("click", function (e) {
    var btn = e.target.closest(".copy");
    if (!btn) return;
    var value = btn.getAttribute("data-copy") || "";
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(
        function () { flash(btn, "Copied"); },
        function () { flash(btn, fallbackCopy(value) ? "Copied" : "Press Ctrl+C"); }
      );
    } else {
      flash(btn, fallbackCopy(value) ? "Copied" : "Press Ctrl+C");
    }
  });
})();
