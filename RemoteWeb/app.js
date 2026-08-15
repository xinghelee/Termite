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
  simulators: zh ? "模拟器" : "Simulators",
  view: zh ? "查看" : "View",
  boot: zh ? "启动" : "Boot",
  booting: zh ? "启动中…" : "Booting…",
  simNone: zh ? "没有找到模拟器" : "No simulators found",
  simUnavailable: zh ? "这台 Mac 上取不到模拟器画面(需要 Xcode)"
                     : "Can't reach the simulator on this Mac (Xcode required)",
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
      return;
    }
    // 终端输出和模拟器画面共用二进制通道,靠 SIMG 魔数分流 —— 不分会把 JPEG 灌进 xterm
    const buf = e.data;
    if (buf.byteLength > 8 && isSimFrame(buf)) {
      drawSimFrame(buf);
    } else if (term && !termScreen.hidden) {
      term.write(new Uint8Array(buf));
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
    case "simList":
      renderSimList(msg);
      break;
    case "simState":
      // 附着失败(模拟器没在跑 / 私有接口不可用)时带 message,退回设备列表
      if (msg.message) {
        toast(msg.message);
        simAttached = null;
        simStage.hidden = true;
        simList.hidden = false;
        $("sim-title").textContent = T.simulators;
        send({ type: "simDevices" });
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

/* ── 模拟器 ──
 * 协议与 iOS 端同一套:simList/simDevices 列设备,simAttach 订阅,
 * 画面走二进制帧(SIMG + 2 字节宽 + 2 字节高 + JPEG),simTouch 回传归一化坐标。 */

const simScreen = $("sim-screen");
const simList = $("sim-list");
const simStage = $("sim-stage");
const simCanvas = $("sim-canvas");
const simCtx = simCanvas.getContext("2d", { alpha: false });

let simAttached = null;     // 正在看的模拟器 udid
let simDecoding = false;    // 上一帧还没解完就丢帧,别积压
let simTouchID = 100;
let simFrameTimes = [];
let simPollTimer = null;

function isSimFrame(buf) {
  const b = new Uint8Array(buf, 0, 4);
  return b[0] === 0x53 && b[1] === 0x49 && b[2] === 0x4d && b[3] === 0x47; // "SIMG"
}

async function drawSimFrame(buf) {
  if (simDecoding || simScreen.hidden) return;
  simDecoding = true;
  try {
    const view = new DataView(buf);
    const w = view.getUint16(4), h = view.getUint16(6);
    const bmp = await createImageBitmap(new Blob([buf.slice(8)], { type: "image/jpeg" }));
    if (simCanvas.width !== w || simCanvas.height !== h) {
      simCanvas.width = w;
      simCanvas.height = h;
    }
    simCtx.drawImage(bmp, 0, 0, w, h);
    bmp.close();
    const now = performance.now();
    simFrameTimes = simFrameTimes.filter((t) => now - t < 1000);
    simFrameTimes.push(now);
    $("sim-fps").textContent = `${simFrameTimes.length} fps`;
  } catch (_) {
    /* 帧坏了就丢,下一帧会来 */
  } finally {
    simDecoding = false;
  }
}

function openSimulators() {
  listScreen.hidden = true;
  simScreen.hidden = false;
  simStage.hidden = true;
  simList.hidden = false;
  $("sim-title").textContent = T.simulators;
  $("sim-fps").textContent = "";
  send({ type: "simDevices" });
  clearInterval(simPollTimer);
  // 只在设备列表页轮询;看画面时靠帧推送,不必再问
  simPollTimer = setInterval(() => {
    if (!simScreen.hidden && !simAttached) send({ type: "simDevices" });
  }, 4000);
}

function closeSimulators() {
  if (simAttached) send({ type: "simDetach" });
  simAttached = null;
  clearInterval(simPollTimer);
  simScreen.hidden = true;
  listScreen.hidden = false;
  startListPolling();
}

function renderSimList(msg) {
  if (!msg.available) {
    simList.replaceChildren(emptyNote(T.simUnavailable));
    return;
  }
  const devices = msg.devices || [];
  if (!devices.length) {
    simList.replaceChildren(emptyNote(T.simNone));
    return;
  }
  simList.replaceChildren(...devices.map((d) => {
    const booted = d.state === "Booted";
    const card = document.createElement("div");
    card.className = "session-card";
    const badge = document.createElement("span");
    badge.className = "badge " + (booted ? "running" : "idle");
    const info = document.createElement("div");
    info.className = "info";
    const title = document.createElement("div");
    title.className = "title";
    title.textContent = d.name;
    const sub = document.createElement("div");
    sub.className = "cwd";
    sub.textContent = d.runtime || "";
    info.append(title, sub);
    const act = document.createElement("button");
    act.className = "key sim-action";
    act.textContent = booted ? T.view : T.boot;
    act.addEventListener("click", (e) => {
      e.stopPropagation();
      if (booted) attachSimulator(d);
      else {
        act.disabled = true;
        act.textContent = T.booting;
        send({ type: "simBoot", udid: d.id });
      }
    });
    card.append(badge, info, act);
    if (booted) card.addEventListener("click", () => attachSimulator(d));
    return card;
  }));
}

function emptyNote(text) {
  const p = document.createElement("p");
  p.className = "sim-empty";
  p.textContent = text;
  return p;
}

function attachSimulator(device) {
  simAttached = device.id;
  simList.hidden = true;
  simStage.hidden = false;
  $("sim-title").textContent = device.name;
  simFrameTimes = [];
  // maxWidth 给屏宽的 2 倍上限:高清屏上别糊,又不至于把 4K 帧推过来
  const maxWidth = Math.min(900, Math.round(simStage.clientWidth * (devicePixelRatio || 1)));
  send({ type: "simAttach", udid: device.id, cols: maxWidth, quality: 0.6, fps: 20 });
}

/* 手指 → 归一化坐标。canvas 是等比铺进容器的,直接用它自己的矩形换算 */
function simPoint(e) {
  const r = simCanvas.getBoundingClientRect();
  return {
    x: Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1),
    y: Math.min(Math.max((e.clientY - r.top) / r.height, 0), 1),
  };
}

let simActiveTouch = null;
let simBottomEdge = false;

simCanvas.addEventListener("pointerdown", (e) => {
  if (!simAttached) return;
  e.preventDefault();
  simCanvas.setPointerCapture(e.pointerId);
  const p = simPoint(e);
  simActiveTouch = ++simTouchID;
  // 从底部安全区起手 = home indicator 手势,要打边缘标记 iOS 才认
  simBottomEdge = p.y > 0.97;
  send({ type: "simTouch", udid: simAttached, x: p.x, y: p.y, phase: 0,
         touchID: simActiveTouch, bottomEdge: simBottomEdge });
});

simCanvas.addEventListener("pointermove", (e) => {
  if (!simAttached || simActiveTouch === null) return;
  const p = simPoint(e);
  send({ type: "simTouch", udid: simAttached, x: p.x, y: p.y, phase: 1,
         touchID: simActiveTouch, bottomEdge: simBottomEdge });
});

function endSimTouch(e) {
  if (!simAttached || simActiveTouch === null) return;
  const p = simPoint(e);
  send({ type: "simTouch", udid: simAttached, x: p.x, y: p.y, phase: 2,
         touchID: simActiveTouch, bottomEdge: simBottomEdge });
  simActiveTouch = null;
}
simCanvas.addEventListener("pointerup", endSimTouch);
simCanvas.addEventListener("pointercancel", endSimTouch);

$("sim-btn").addEventListener("click", openSimulators);
$("sim-back").addEventListener("click", () => {
  if (simAttached) {           // 看画面时先退回设备列表,再点一次才离开
    send({ type: "simDetach" });
    simAttached = null;
    simStage.hidden = true;
    simList.hidden = false;
    $("sim-title").textContent = T.simulators;
    $("sim-fps").textContent = "";
    send({ type: "simDevices" });
    return;
  }
  closeSimulators();
});

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
