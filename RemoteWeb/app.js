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
};

document.querySelectorAll("[data-i18n]").forEach((el) => {
  el.textContent = T[el.dataset.i18n] || "";
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
  if (wsReady && attachedID) ws.send(encoder.encode(text));
}

/* ── 控制消息 ── */

function handleControl(msg) {
  switch (msg.type) {
    case "list":
      renderList(msg.sessions);
      break;
    case "attached":
      ptyCols = msg.cols;
      ptyRows = msg.rows;
      openTerminal();
      break;
    case "resize":
      ptyCols = msg.cols;
      ptyRows = msg.rows;
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

function renderList(sessions) {
  listEmpty.hidden = sessions.length > 0;
  sessionList.replaceChildren(
    ...sessions.map((s) => {
      const card = document.createElement("div");
      card.className = "session-card";
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
      if (s.alive) card.addEventListener("click", () => attach(s));
      return card;
    })
  );
}

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

/* 字号自适应:列数装进屏宽(下限 7px,更宽就横向滚动) */
function fitFont() {
  if (!term) return;
  const holder = $("term-holder");
  const available = holder.clientWidth - 8;
  // Menlo 字宽 ≈ 0.6 × 字号;逐档试到能放下为止
  let size = 16;
  while (size > 7 && ptyCols * size * 0.602 > available) size--;
  term.options.fontSize = size;
  $("term-size").textContent = `${ptyCols}×${ptyRows} · ${size}px`;
}

function backToList() {
  if (attachedID) send({ type: "detach" });
  attachedID = null;
  currentSession = null;
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

window.addEventListener("resize", fitFont);

connect();
startListPolling();
