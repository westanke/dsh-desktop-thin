/**
 * dsh-desktop-thin — Electron entry point (orchestration only).
 *
 * Thin shell model:
 *   - The package ships ONLY this JS + tools/ (≈160KB deb).
 *   - Electron, Node and the `dsh` kernel are fetched on first launch into a
 *     per-user runtime dir by tools/bootstrap.sh.
 *   - At runtime we resolve the kernel, inject DSH_HOME, and supervise it.
 *
 * dsh-app:// protocol:
 *   - dsh-app://app/*  → forwarded to the local dsh web Host (authenticated).
 *   - dsh-app://shell/* → shell-owned static assets (update dialogs etc.).
 *   The scheme registration mirrors apps/desktop/src/main.ts; the Host trust
 *   fence is satisfied via `dsh web --trusted-host 127.0.0.1` (single-user desktop).
 *
 * @module main
 */

import { existsSync, readFileSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'
import { app, BrowserWindow, ipcMain, Menu, protocol, net } from 'electron'
import { readRuntimeConfig, resolveKernelPaths, buildKernelEnv, resolveDshHome } from './kernel-runtime.js'
import { serveWebDocument, forwardWebRequest } from './web-document.js'

const here = dirname(fileURLToPath(import.meta.url))
const CONFIG = JSON.parse(readFileSync(join(here, '..', 'config.json'), 'utf8'))
const RUNTIME = readRuntimeConfig(CONFIG)
const SCHEME = 'dsh-app'

// 官方家目录：默认 $HOME/.dsh，DSH_HOME 可覆盖（多 Home 切换）。
let dshHome = resolveDshHome()
// 壳自带静态资源目录（dsh-app://shell/）
const SHELL_WEB_ROOT = join(here, '..', 'assets', 'shell')

// 官方 scheme 注册（与 apps/desktop/src/main.ts 同特权集）。
protocol.registerSchemesAsPrivileged([{
  scheme: SCHEME,
  privileges: {
    standard: true, secure: true, supportFetchAPI: true,
    corsEnabled: true, stream: true, codeCache: true,
  },
}])

let mainWindow = null
let kernelProcess = null
let hostBaseUrl = null   // 形如 http://127.0.0.1:PORT（经 --trusted-host 已信任）
let hostCookie = ''

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    show: false,
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  })
  mainWindow.loadURL(`data:text/html,<h2 style="font-family:sans-serif;padding:2rem">DeepSeek Harness — 正在启动内核…</h2>`)
  mainWindow.once('ready-to-show', () => mainWindow.show())
  return mainWindow
}

/** 解析 dsh web 打印的监听地址（形如 http://127.0.0.1:PORT）。 */
function parseListenUrl(text) {
  const m = /https?:\/\/127\.0\.0\.1:\d+/.exec(text)
  return m ? m[0] : null
}

async function bootKernel() {
  const { dshBin, runtimeDir, ready } = resolveKernelPaths(RUNTIME)
  if (!ready) {
    console.error('[thin] kernel not ready — run tools/bootstrap.sh first')
    return null
  }
  await mkdir(dshHome, { recursive: true })

  const args = [
    'web', '--profile', CONFIG.kernel?.profile ?? 'web',
    '--no-open', '--port', '0',
    '--trusted-host', '127.0.0.1',
  ]
  const env = buildKernelEnv({ parentEnv: process.env, dshHome, runElectronAsNode: false })

  const { spawn } = await import('node:child_process')
  const child = spawn(dshBin, args, { env, stdio: ['ignore', 'pipe', 'pipe'], cwd: here })
  kernelProcess = child

  const onData = (b) => {
    const s = b.toString()
    process.stdout.write(`[dsh] ${s}`)
    if (!hostBaseUrl) {
      const u = parseListenUrl(s)
      if (u) {
        hostBaseUrl = u
        console.log(`[thin] kernel Host at ${hostBaseUrl}`)
        if (mainWindow) mainWindow.loadURL(`${SCHEME}://app/`)
      }
    }
  }
  child.stdout.on('data', onData)
  child.stderr.on('data', (b) => process.stderr.write(`[dsh:err] ${b}`))
  child.on('exit', (code) => console.log(`[thin] kernel exited code=${code}`))
  return child
}

/** dsh-app:// scheme handler：app→Host 转发，shell→静态资源。 */
function registerSchemeHandler() {
  protocol.handle(SCHEME, async (request) => {
    const url = new URL(request.url)
    if (url.host === 'shell') {
      return serveWebDocument(request, SHELL_WEB_ROOT)
    }
    if (url.host === 'app') {
      if (!hostBaseUrl) return new Response('kernel not ready', { status: 503 })
      return forwardWebRequest(request, hostBaseUrl, hostCookie)
    }
    return new Response(null, { status: 404 })
  })
}

function buildAppMenu() {
  const template = [
    {
      label: '首页',
      submenu: [{ role: 'reload' }, { role: 'toggleDevTools' }, { type: 'separator' }, { role: 'quit' }],
    },
  ]
  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

app.whenReady().then(async () => {
  buildAppMenu()
  registerSchemeHandler()
  createWindow()
  ipcMain.handle('dsh:switchHome', async (_e, nextPath) => {
    dshHome = nextPath
    await mkdir(dshHome, { recursive: true })
    console.log(`[thin] switching home -> ${dshHome}`)
    return { dshHome }
  })
  await bootKernel()
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    kernelProcess?.kill()
    app.quit()
  }
})
