// machine_editor/lua_table.js -- read and write the data-only Lua files in machines/ (`return { ... }`).
// Subset: tables, "strings" / 'strings' / [[long strings]], numbers, true / false / nil, -- comments.  No functions or expressions.
// parseLua(src) -> { header, value }   header = the comment text before `return` (kept so a save does not lose it)
// serializeLua(value, header) -> text
(function (root) {
  function parseLua(src) {
    let i = 0;
    const n = src.length;
    const err = (m) => { throw new Error(m + " at line " + (src.slice(0, i).split("\n").length)); };
    function ws() {
      for (;;) {
        while (i < n && /\s/.test(src[i])) i++;
        if (src.startsWith("--", i)) {
          const m = /^--\[(=*)\[/.exec(src.slice(i, i + 24));
          if (m) { const close = "]" + m[1] + "]"; const e = src.indexOf(close, i); i = e < 0 ? n : e + close.length; }
          else { while (i < n && src[i] !== "\n") i++; }
        } else break;
      }
    }
    function quoted(q) {
      i++;
      let out = "";
      while (i < n && src[i] !== q) {
        if (src[i] === "\\") {
          i++;
          const c = src[i];
          out += c === "n" ? "\n" : c === "t" ? "\t" : c === "r" ? "\r" : c;
        } else out += src[i];
        i++;
      }
      if (i >= n) err("unterminated string");
      i++;
      return out;
    }
    function longStr() {
      const m = /^\[(=*)\[/.exec(src.slice(i, i + 24));
      const close = "]" + m[1] + "]";
      const start = i + m[0].length;
      const e = src.indexOf(close, start);
      if (e < 0) err("unterminated long string");
      i = e + close.length;
      let s = src.slice(start, e);
      if (s[0] === "\n") s = s.slice(1);
      return s;
    }
    function value() {
      ws();
      const c = src[i];
      if (c === "{") return table();
      if (c === '"' || c === "'") return quoted(c);
      if (c === "[" && /^\[=*\[/.test(src.slice(i, i + 24))) return longStr();
      if (/[-0-9.]/.test(c)) {
        const m = /^-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?/.exec(src.slice(i));
        if (!m) err("bad number");
        i += m[0].length;
        return parseFloat(m[0]);
      }
      const m = /^[A-Za-z_]\w*/.exec(src.slice(i));
      if (m) {
        i += m[0].length;
        if (m[0] === "true") return true;
        if (m[0] === "false") return false;
        if (m[0] === "nil") return null;
        err("unexpected name '" + m[0] + "' (data files hold literals only)");
      }
      err("unexpected '" + c + "'");
    }
    function table() {
      i++;
      const arr = [];
      const obj = {};
      let hasKey = false;
      for (;;) {
        ws();
        if (i >= n) err("unterminated table");
        if (src[i] === "}") { i++; break; }
        if (src[i] === "[" && !/^\[=*\[/.test(src.slice(i, i + 24))) {
          i++;
          const k = value();
          ws(); if (src[i] !== "]") err("expected ]"); i++;
          ws(); if (src[i] !== "=") err("expected ="); i++;
          obj[k] = value();
          hasKey = true;
        } else {
          const m = /^[A-Za-z_]\w*/.exec(src.slice(i));
          let done = false;
          if (m) {
            const save = i;
            i += m[0].length;
            ws();
            if (src[i] === "=" && src[i + 1] !== "=") { i++; obj[m[0]] = value(); hasKey = true; done = true; }
            else i = save;
          }
          if (!done) arr.push(value());
        }
        ws();
        if (src[i] === "," || src[i] === ";") i++;
      }
      if (hasKey) { arr.forEach((v, k) => { obj[k + 1] = v; }); return obj; }
      return arr;
    }
    const m = /(^|\n)[ \t]*return\b/.exec(src);
    if (!m) err("no `return` found");
    const header = src.slice(0, m.index + (m[1] ? 1 : 0)).replace(/\s+$/, "");
    i = m.index + m[0].length;
    const v = value();
    return { header, value: v };
  }

  const KEYORDER = ["name", "version", "initial", "stance_machine", "share_machine", "nodes", "edges", "any_edges", "any_pos",
    "from", "to", "prio", "hold_s", "min_stay_s", "note", "when", "all", "any", "not", "sig", "op", "val",
    "stance", "share", "hook", "cfg", "ramp_s", "x", "y"];
  const KEEP = new Set(["nodes", "cfg"]);       // keys whose own keys are names, kept in insertion order
  const LUAKW = new Set(["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"]);
  const MAXW = 110;

  const key = (k) => (/^[A-Za-z_]\w*$/.test(k) && !LUAKW.has(k)) ? k : "[" + lstr(k) + "]";
  function lstr(s) { return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r") + '"'; }
  function num(v) { return Number.isInteger(v) ? String(v) : String(parseFloat(v.toFixed(6))); }

  function ser(v, ind, depth, keep) {
    if (v === null || v === undefined) return "nil";
    if (typeof v === "string") return lstr(v);
    if (typeof v === "number") return num(v);
    if (typeof v === "boolean") return v ? "true" : "false";
    let items;
    if (Array.isArray(v)) {
      items = v.map((x) => ser(x, ind + "  ", depth + 1, false));
    } else {
      let ks = Object.keys(v).filter((k) => v[k] !== undefined);
      if (!keep) {
        ks = ks.map((k, j) => ({ k, j, r: KEYORDER.indexOf(k) < 0 ? 99 : KEYORDER.indexOf(k) }))
          .sort((a, b) => a.r - b.r || a.j - b.j).map((o) => o.k);
      }
      items = ks.map((k) => key(k) + " = " + ser(v[k], ind + "  ", depth + 1, KEEP.has(k)));
    }
    if (!items.length) return "{}";
    // an edge: its settings on one line, the condition under it
    if (depth === 3 && !Array.isArray(v) && v.when !== undefined) {
      const ks2 = Object.keys(v).filter((k) => k !== "when" && v[k] !== undefined);
      const sorted = ks2.map((k, j) => ({ k, j, r: KEYORDER.indexOf(k) < 0 ? 99 : KEYORDER.indexOf(k) })).sort((a, b) => a.r - b.r || a.j - b.j).map((o) => key(o.k) + " = " + ser(v[o.k], ind + "  ", 4, KEEP.has(o.k)));
      return "{ " + sorted.join(", ") + ",\n" + ind + "  when = " + ser(v.when, ind + "  ", 4, false) + " }";
    }
    const one = "{ " + items.join(", ") + " }";
    if (depth > 2 && one.indexOf("\n") < 0 && ind.length + one.length <= MAXW) return one;
    return "{\n" + items.map((s) => ind + "  " + s).join(",\n") + ",\n" + ind + "}";
  }

  function serializeLua(value, header) {
    return (header ? header.replace(/\s+$/, "") + "\n" : "") + "return " + ser(value, "", 0, false) + "\n";
  }

  const api = { parseLua, serializeLua };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.LuaTable = api;
})(typeof window !== "undefined" ? window : this);
