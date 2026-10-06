// Resolve the dsh kernel binary + Node used to run it.
//
// Unlike the official desktop shell, this thin shell keeps NO runtime in the
// package. Electron, Node and `dsh` are fetched on first launch into a per-user
// runtime dir (see tools/bootstrap.sh). Here we only *resolve* what bootstrap
// already placed, and honour an explicit override via DSH_KERNEL_BIN / PATH.

import { existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'

/** 官方家目录：resolveDshHome 默认 $HOME/.dsh，可被 DSH_HOME 覆盖。 */
export function resolveDshHome() {
  return process.env.DSH_HOME ?? join(process.env.HOME ?? homedir(), '.dsh')
}

/** Read the runtime layout from config.json (already loaded by main). */
export function readRuntimeConfig(config) {
  const r = config?.runtime ?? {}
  // 运行时节点的官方落点：$DSH_HOME/dsh-runtimes/...（与官方 Python/Office 同目录树）。
  const dshHome = resolveDshHome()
  const runtimeDir = (r.runtimeDir ?? '$DSH_HOME/dsh-runtimes/dsh-thin-runtime')
    .replace('$DSH_HOME', dshHome)
    .replace('$HOME', process.env.HOME ?? homedir())
  return {
    runtimeDir,
    dshVersion: r.dshVersion ?? '0.2.0',
    nodeVersion: r.nodeVersion ?? 'v24.19.0',
    electronVersion: r.electronVersion ?? 'v33.3.0',
    dshDistBase: r.dshDistBase ?? 'https://registry.npmmirror.com/-/binary/dsh',
    registry: r.registry ?? 'https://registry.npmmirror.com',
    nodeMirrors: r.nodeMirrors ?? [],
    electronMirrors: r.electronMirrors ?? [],
  }
}

/**
 * Resolve where `dsh` and the Node that runs it live after bootstrap.
 * @returns {{ dshBin: string, nodeBin: string|null, runtimeDir: string, ready: boolean }}
 */
export function resolveKernelPaths(runtime) {
  const { runtimeDir } = runtime

  // Explicit override for a system-installed dsh (self-hosted path).
  const systemBin = process.env.DSH_KERNEL_BIN
  if (systemBin && existsSync(systemBin)) {
    return { dshBin: systemBin, nodeBin: null, runtimeDir, ready: true }
  }

  const candidates = [
    join(runtimeDir, 'dsh', 'bin', 'dsh'),
    join(runtimeDir, 'dsh', 'dsh'),
    join(runtimeDir, 'node_modules', '.bin', 'dsh'),
  ]
  for (const c of candidates) {
    if (existsSync(c)) return { dshBin: c, nodeBin: null, runtimeDir, ready: true }
  }

  // Fall back to a dsh on PATH (e.g. globally installed @deepseek-ai/dsh).
  const pathDirs = (process.env.PATH ?? '').split(':').filter(Boolean)
  for (const dir of pathDirs) {
    const p = join(dir, 'dsh')
    if (existsSync(p)) return { dshBin: p, nodeBin: null, runtimeDir, ready: true }
  }

  return { dshBin: '', nodeBin: null, runtimeDir, ready: false }
}

/** Build the env block handed to the kernel process. */
export function buildKernelEnv({ parentEnv, dshHome, runElectronAsNode }) {
  const env = { ...parentEnv }
  env.DSH_HOME = dshHome
  if (runElectronAsNode) {
    env.ELECTRON_RUN_AS_NODE = '1'
  }
  return env
}
