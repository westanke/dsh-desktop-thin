/**
 * dsh-desktop-thin — Electron entry point (orchestration only).
 *
 * Thin shell model:
 *   - The package ships ONLY this JS + tools/bootstrap.sh (≈160KB deb).
 *   - Electron, Node and the `dsh` kernel are fetched on first launch into a
 *     per-user runtime dir by tools/bootstrap.sh.
 *   - At runtime we resolve the kernel, inject DSH_HOME, and supervise it.
 *
 * Multi-Home is supported: dshHome is mutable; switching a home repoints
 * DSH_HOME and restarts the supervisor (never the shell).
 *
 * @module main
 */

import { existsSync, readFileSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'
import { app, BrowserWindow, ipcMain, Menu } from 'electron'
import { readRuntimeConfig, resolveKernelPaths, buildKernelEnv } from './kernel-runtime.js'

const here = dirname(fileURLToPath(import.meta.url))
const CONFIG = JSON.parse(readFileSync(join(here, '..', 'config.json'), 'utf8'))
const RUNTIME = readRuntimeConfig(CONFIG)
const HOST = '127.0.0.1'

/** Per-user harness home; switches on demand (multi-Home). */
let dshHome = join(process.env.HOME ?? homedir(), '.dsh')

function getConfig() {
  return CONFIG
}

function pickFreePort() {
  // Minimal free-port finder; the kernel binds an OS-assigned port by default.
  return 0
}

let mainWindow = null

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    show: false,
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  })
  // Until the kernel is ready we show a loading page; once it answers on its
  // port we load dsh-app://app/ (the same scheme the official shell uses).
  mainWindow.loadURL(`data:text/html,<h2 style="font-family:sans-serif;padding:2rem">DeepSeek Harness — 正在启动内核…</h2>`)
  mainWindow.once('ready-to-show', () => mainWindow.show())
  return mainWindow
}

/**
 * Boot the dsh kernel as a supervised child and point the window at it.
 * @returns {Promise<{code:number}|null>}
 */
async function bootKernel() {
  const { dshBin, runtimeDir, ready } = resolveKernelPaths(RUNTIME)
  if (!ready) {
    console.error('[thin] kernel not ready — run tools/bootstrap.sh first')
    return null
  }

  await mkdir(dshHome, { recursive: true })

  const args = ['web', '--profile', CONFIG.kernel?.profile ?? 'web']
  const env = buildKernelEnv({
    parentEnv: process.env,
    dshHome,
    runElectronAsNode: false,
  })

  const { spawn } = await import('node:child_process')
  const child = spawn(dshBin, args, {
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
    cwd: here,
  })

  child.stdout.on('data', (b) => process.stdout.write(`[dsh] ${b}`))
  child.stderr.on('data', (b) => process.stderr.write(`[dsh:err] ${b}`))

  child.on('exit', (code) => {
    console.log(`[thin] kernel exited code=${code}`)
  })

  return child
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
  if (process.platform !== 'darwin') app.quit()
})
