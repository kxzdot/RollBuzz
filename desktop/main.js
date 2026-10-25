// Склад тканей для Windows: окно программы. Сам экран программы при каждом запуске
// загружается с сервера (его публикует сборка на GitHub), поэтому обновлять установку не нужно.
const { app, BrowserWindow, session, shell, Menu } = require("electron");
const path = require("path");

if (!app.requestSingleInstanceLock()) { app.quit(); }

let win = null;
function createWindow() {
  win = new BrowserWindow({
    width: 1280, height: 880, minWidth: 420, minHeight: 600,
    title: "Склад тканей", icon: path.join(__dirname, "icon.ico"),
    backgroundColor: "#eceee8", autoHideMenuBar: true, show: false,
    webPreferences: { contextIsolation: true, nodeIntegration: false, spellcheck: false }
  });
  Menu.setApplicationMenu(null);
  win.once("ready-to-show", () => win.show());
  // ссылки наружу (например, PDF отчёта) открываются в обычном браузере
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/i.test(url)) shell.openExternal(url); return { action: "deny" }; });
  win.webContents.on("will-navigate", (e, url) => { if (/^https?:/i.test(url)) { e.preventDefault(); shell.openExternal(url); } });
  // F5 — обновить, Ctrl+колесо/плюс/минус — масштаб
  win.webContents.on("before-input-event", (e, input) => {
    if (input.type === "keyDown" && input.key === "F5") { win.webContents.reload(); e.preventDefault(); }
    if (input.type === "keyDown" && input.control && (input.key === "=" || input.key === "+")) { win.webContents.setZoomLevel(win.webContents.getZoomLevel() + 0.5); e.preventDefault(); }
    if (input.type === "keyDown" && input.control && input.key === "-") { win.webContents.setZoomLevel(win.webContents.getZoomLevel() - 0.5); e.preventDefault(); }
    if (input.type === "keyDown" && input.control && input.key === "0") { win.webContents.setZoomLevel(0); e.preventDefault(); }
  });
  win.loadFile(path.join(__dirname, "app", "launcher.html"));
}

app.on("second-instance", () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(() => {
  // камера ноутбука для сканера штрихкодов
  const allow = ["media", "clipboard-sanitized-write", "fullscreen"];
  session.defaultSession.setPermissionRequestHandler((wc, perm, cb) => cb(allow.includes(perm)));
  session.defaultSession.setPermissionCheckHandler((wc, perm) => allow.includes(perm));
  createWindow();
});
app.on("window-all-closed", () => app.quit());
