/* Termite 远程访问 Web 客户端。
 * 协议:WS 文本帧 = JSON 控制(list/attach/detach/resize/exited),
 *       WS 二进制帧 = 终端输出(服务端→)/ 键盘输入(→服务端)。
 * PTY 尺寸由 Mac 端拥有,这里按列数反推字号自适应屏宽,超宽则横向滚动。 */

"use strict";

const zh = navigator.language.startsWith("zh");
const T = {
  back: zh ? "‹ 会话" : "‹ Back",
  noSessions: zh ? "没有打开的会话" : "No open sessions",
  connecting: zh ? "连接中…" : "Connecting…",
  reconnecting: zh ? "连接断开,重连中…" : "Reconnecting…",
  denied: zh ? "链接无效或已过期,请在 Mac 上重新获取" : "Link invalid or expired — get a fresh one on your Mac",
  exited: zh ? "会话已结束" : "Session ended",
  connected: zh ? "已连接" : "Connected",
  gone: zh ? "会话不存在或已关闭" : "Session gone",
  lockedBy: zh ? "%@ 正在操作这个会话" : "%@ is driving this session",
  lockedHint: zh ? "等对方交还后才能输入" : "You can watch until they hand it back",
  claimHint: zh ? "点上方「接管」即可操作" : "Hit Take over above to drive it",
  takeOver: zh ? "接管" : "Take over",
  handBack: zh ? "交还" : "Hand back",
  waiting: zh ? "等你回复" : "Waiting on you",
  other: zh ? "其他" : "Other",
  search: zh ? "搜索会话、项目、路径" : "Search sessions, projects, paths",
  noMatch: zh ? "没有匹配的会话" : "No matching sessions",
};

/* 「已等 3 分钟」——手机上第一眼要能判断该不该现在管 */
function waitedText(sec) {
  if (sec == null) return "";
  if (sec < 60) return zh ? `已等 ${sec} 秒` : `waiting ${sec}s`;
  const m = Math.floor(sec / 60);
  if (m < 60) return zh ? `已等 ${m} 分钟` : `waiting ${m}m`;
  const h = Math.floor(m / 60);
  return zh ? `已等 ${h} 小时` : `waiting ${h}h`;
}

document.querySelectorAll("[data-i18n]").forEach((el) => {
  el.textContent = T[el.dataset.i18n] || "";
});
document.querySelectorAll("[data-i18n-ph]").forEach((el) => {
  el.placeholder = T[el.dataset.i18nPh] || "";
});

const $ = (id) => document.getElementById(id);
const listScreen = $("list-screen");
const termScreen = $("term-screen");
const sessionList = $("session-list");
const listEmpty = $("list-empty");
const connState = $("conn-state");
const overlay = $("overlay");
const overlayText = $("overlay-text");

const token = new URLSearchParams(location.search).get("t") || "";
const encoder = new TextEncoder();

/* 手机上能读的字号下限。Mac 那边通常 80 列,硬塞进手机宽度会缩到 10px 以下,
   所以接管时不再继承 Mac 网格,而是按这个字号反推自己的列数(tmux 语义)。 */
const READABLE_FONT = 13;
const CHAR_W = 0.602;   // Menlo 等宽字的字宽 ≈ 0.602 × 字号
const LINE_H = 1.2;     // xterm 默认行高倍数

function deviceName() {
  const ua = navigator.userAgent;
  if (ua.includes("iPhone")) return "iPhone (Web)";
  if (ua.includes("iPad")) return "iPad (Web)";
  if (ua.includes("Android")) return "Android (Web)";
  return "Web";
}

/* 这块屏按 READABLE_FONT 能放下多大的网格 */
function deviceGrid(size = READABLE_FONT) {
  const holder = $("term-holder");
  const w = Math.max(0, holder.clientWidth - 8);
  const h = Math.max(0, holder.clientHeight - 4);
  return {
    cols: Math.max(20, Math.floor(w / (size * CHAR_W))),
    rows: Math.max(10, Math.floor(h / (size * LINE_H))),
  };
}

let ws = null;
let wsReady = false;
let retryDelay = 500;
let term = null;
let attachedID = null;      // 当前附着的会话(重连后自动重附)
let currentSession = null;  // 列表里的会话摘要(标题栏用)
let ptyCols = 80;
let ptyRows = 24;
let listTimer = null;
let ctrlArmed = false;
let controlLocked = false;  // 不是本端在操作:只看不动
let controlState = null;    // 最近一次下发的控制权(接管按钮据此决定动作)

/* ── WebSocket ── */

function connect() {
  showOverlay(attachedID ? T.reconnecting : T.connecting);
  ws = new WebSocket(`ws://${location.host}/ws?t=${encodeURIComponent(token)}`);
  ws.binaryType = "arraybuffer";

  ws.onopen = () => {
    wsReady = true;
    retryDelay = 500;
    hideOverlay();
    connState.textContent = T.connected;
    connState.classList.add("ok");
    if (attachedID) {
      // 断线重连:重置终端重放镜像,状态接续
      if (term) term.reset();
      send({ type: "attach", id: attachedID });
    } else {
      send({ type: "list" });
    }
  };

  ws.onmessage = (e) => {
    if (typeof e.data === "string") {
      handleControl(JSON.parse(e.data));
    } else if (term && !termScreen.hidden) {
      term.write(new Uint8Array(e.data));
    }
  };

  ws.onclose = (e) => {
    wsReady = false;
    connState.textContent = "";
    connState.classList.remove("ok");
    if (e.code === 1008 || e.reason === "forbidden") {
      showOverlay(T.denied);
      return;
    }
    // 403 升级失败也走到这:token 错时服务端直接断 TCP,靠重试上限兜底提示
    setTimeout(connect, retryDelay);
    retryDelay = Math.min(retryDelay * 1.7, 8000);
    if (retryDelay > 4000) showOverlay(T.reconnecting);
  };

  ws.onerror = () => ws.close();
}

function send(obj) {
  if (wsReady) ws.send(JSON.stringify(obj));
}

function sendInput(text) {
  if (controlLocked) return;
  if (wsReady && attachedID) ws.send(encoder.encode(text));
}

/* 控制权:服务端逐连接下发。旧服务端不带 control 字段 → 视为无人接管(老行为) */
function applyControl(control) {
  controlState = control || null;
  controlLocked = !!(control && control.locked);
  const scrim = $("lock-scrim");
  const btn = $("control-btn");
  if (controlLocked) {
    const who = (control && control.controller) || (zh ? "另一台设备" : "Another device");
    const hint = control && control.claimable ? T.claimHint : T.lockedHint;
    $("lock-text").textContent = T.lockedBy.replace("%@", who) + "\n" + hint;
    scrim.style.whiteSpace = "pre-line";
  }
  scrim.hidden = !controlLocked;
  // 没有 control 字段(老服务端)就别显示这个按钮,免得点了没反应
  btn.hidden = !control;
  btn.textContent = control && control.mine ? T.handBack : T.takeOver;
  btn.disabled = !!(control && control.locked && !control.claimable);
}

$("control-btn").addEventListener("click", () => {
  if (!attachedID) return;
  if (controlState && controlState.mine) {
    send({ type: "release", id: attachedID });
  } else if (controlState && controlState.claimable) {
    // 接管 = 要自己的宽度:发这块屏按可读字号算出的网格,别继承 Mac 的 80 列
    const g = deviceGrid();
    send({ type: "claim", id: attachedID, cols: g.cols, rows: g.rows, device: deviceName() });
  }
});

/* ── 控制消息 ── */

function handleControl(msg) {
  switch (msg.type) {
    case "list":
      renderList(msg.sessions);
      break;
    case "attached":
      ptyCols = msg.cols;
      ptyRows = msg.rows;
      applyControl(msg.control);
      openTerminal();
      break;
    // 服务端发的是 viewport;resize 是旧名,一起认
    case "viewport":
    case "resize":
      ptyCols = msg.cols;
      ptyRows = msg.rows;
      applyControl(msg.control);
      if (term) {
        term.resize(ptyCols, ptyRows);
        fitFont();
      }
      break;
    case "exited":
      toast(T.exited);
      backToList();
      break;
    case "error":
      toast(msg.message || T.gone);
      backToList();
      break;
  }
}

/* ── 会话列表 ── */

let lastSessions = [];
let filterText = "";

function sessionCard(s) {
  const card = document.createElement("div");
  card.className = "session-card" + (s.attention === "input" && s.alive ? " waiting" : "");
  const badge = document.createElement("span");
  badge.className = "badge " + (!s.alive ? "dead" : s.attention ? "attention" : s.running ? "running" : "idle");
  const info = document.createElement("div");
  info.className = "info";
  const title = document.createElement("div");
  title.className = "title";
  title.textContent = s.title;
  const cwd = document.createElement("div");
  cwd.className = "cwd";
  cwd.textContent = s.cwd || s.shell;
  info.append(title, cwd);
  card.append(badge, info);
  // 等待中的会话把等了多久摆在右边:决定「现在管还是待会管」全靠它
  if (s.alive && s.attention === "input") {
    const waited = document.createElement("div");
    waited.className = "waited";
    waited.textContent = waitedText(s.attentionSeconds);
    card.append(waited);
  }
  if (s.alive) card.addEventListener("click", () => attach(s));
  return card;
}

function sectionHeader(name, count, color) {
  const h = document.createElement("div");
  h.className = "section";
  const dot = document.createElement("span");
  dot.className = "section-dot";
  if (color) dot.style.background = color;
  const label = document.createElement("span");
  label.className = "section-name";
  label.textContent = name;
  const n = document.createElement("span");
  n.className = "section-count";
  n.textContent = count;
  h.append(dot, label, n);
  return h;
}

function matches(s) {
  if (!filterText) return true;
  const q = filterText.toLowerCase();
  return [s.title, s.cwd, s.project, s.shell, s.space]
    .some((v) => v && v.toLowerCase().includes(q));
}

function renderList(sessions) {
  lastSessions = sessions;
  const shown = sessions.filter(matches);
  listEmpty.hidden = shown.length > 0;
  listEmpty.textContent = sessions.length && !shown.length ? T.noMatch : T.noSessions;

  const out = [];
  // 「谁在等我」是手机上的头等大事:单独置顶一组,不跟项目混排
  const waiting = shown.filter((s) => s.alive && s.attention === "input");
  if (waiting.length) {
    waiting.sort((a, b) => (b.attentionSeconds || 0) - (a.attentionSeconds || 0));
    out.push(sectionHeader(T.waiting, waiting.length));
    out[out.length - 1].classList.add("urgent");
    waiting.forEach((s) => out.push(sessionCard(s)));
  }
  // 其余按项目归堆,对齐 Mac 侧边栏的语义
  const groups = new Map();
  for (const s of shown) {
    if (s.alive && s.attention === "input") continue;
    const key = s.project || T.other;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(s);
  }
  for (const [name, items] of groups) {
    out.push(sectionHeader(name, items.length, items[0].projectColor));
    items.forEach((s) => out.push(sessionCard(s)));
  }
  sessionList.replaceChildren(...out);
}

$("search").addEventListener("input", (e) => {
  filterText = e.target.value.trim();
  renderList(lastSessions);
});

function startListPolling() {
  send({ type: "list" });
  clearInterval(listTimer);
  listTimer = setInterval(() => {
    if (!listScreen.hidden) send({ type: "list" });
  }, 3000);
}

/* ── 终端 ── */

function attach(session) {
  currentSession = session;
  attachedID = session.id;
  $("term-title").textContent = session.title;
  if (term) term.reset();
  send({ type: "attach", id: session.id });
}

function openTerminal() {
  listScreen.hidden = true;
  termScreen.hidden = false;
  clearInterval(listTimer);
  if (!term) {
    term = new Terminal({
      cols: ptyCols,
      rows: ptyRows,
      fontFamily: "ui-monospace, Menlo, Consolas, monospace",
      fontSize: 13,
      theme: {
        background: "#14161a",
        foreground: "#e6e6e6",
        cursor: "#e8a33d",
        selectionBackground: "rgba(232, 163, 61, 0.35)",
      },
      scrollback: 3000,
      convertEol: false,
    });
    term.open($("term-holder"));
    term.onData((data) => {
      if (ctrlArmed && data.length === 1) {
        disarmCtrl();
        const code = data.toUpperCase().charCodeAt(0);
        if (code >= 64 && code < 96) {
          sendInput(String.fromCharCode(code & 0x1f));
          return;
        }
      }
      sendInput(data);
    });
  } else {
    term.resize(ptyCols, ptyRows);
  }
  $("term-size").textContent = `${ptyCols}×${ptyRows}`;
  fitFont();
  term.focus();
}

/* 字号自适应。自己接管时网格本就是按 READABLE_FONT 要来的,直接用;
   跟随 Mac 时只能把它的列数塞进屏宽(下限 7px,再宽就横向滚动)。 */
function fitFont() {
  if (!term) return;
  const holder = $("term-holder");
  const available = holder.clientWidth - 8;
  const mine = !!(controlState && controlState.mine);
  let size = READABLE_FONT;
  if (!mine) {
    size = 16;
    while (size > 7 && ptyCols * size * CHAR_W > available) size--;
  }
  term.options.fontSize = size;
  $("term-size").textContent = mine ? `${ptyCols}×${ptyRows}` : `${ptyCols}×${ptyRows} · ${size}px`;
  // 跟随 Mac 且已经缩到看不清:提示这里可以拿自己的宽度
  const tiny = !mine && size < 11 && controlState && controlState.claimable;
  $("term-size").classList.toggle("warn", !!tiny);
}

function backToList() {
  if (attachedID) send({ type: "detach" });
  attachedID = null;
  currentSession = null;
  applyControl(null);
  termScreen.hidden = true;
  listScreen.hidden = false;
  startListPolling();
}

/* ── 按键条 ── */

document.querySelectorAll("#key-bar .key[data-send]").forEach((btn) => {
  btn.addEventListener("click", () => {
    sendInput(btn.dataset.send);
    if (term) term.focus();
  });
});

const ctrlBtn = $("ctrl-btn");
ctrlBtn.addEventListener("click", () => {
  ctrlArmed = !ctrlArmed;
  ctrlBtn.classList.toggle("armed", ctrlArmed);
  if (term) term.focus();
});

function disarmCtrl() {
  ctrlArmed = false;
  ctrlBtn.classList.remove("armed");
}

$("back-btn").addEventListener("click", backToList);

/* ── 杂项 ── */

function showOverlay(text) {
  overlayText.textContent = text;
  overlay.hidden = false;
}

function hideOverlay() {
  overlay.hidden = true;
}

let toastTimer = null;
function toast(text) {
  showOverlay(text);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(hideOverlay, 1800);
}

/* 旋转屏幕 / 键盘弹收都会改可视高度。自己接管时网格是我们说了算的,
   重新按新尺寸要一次;跟随 Mac 时只调字号。防抖是必要的 —— iOS 上
   键盘动画期间 resize 会连发几十次 */
let resizeTimer = null;
window.addEventListener("resize", () => {
  fitFont();
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (!attachedID || !controlState || !controlState.mine) return;
    const g = deviceGrid();
    if (g.cols === ptyCols && g.rows === ptyRows) return;
    send({ type: "claim", id: attachedID, cols: g.cols, rows: g.rows, device: deviceName() });
  }, 250);
});

connect();
startListPolling();
