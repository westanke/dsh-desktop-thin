/**
 * 移植自官方 apps/desktop/src/web-document.ts。
 *
 * dsh-app:// 是官方桌面壳私有的、已注册 scheme；dsh 内核（Web Host）并不认识
 * 这个 scheme——它只是被转发的后端。薄壳要支持 dsh-app://app/，必须自己实现：
 *   1) protocol.registerSchemesAsPrivileged 注册 scheme（见 main.js 顶部）
 *   2) 把 dsh-app://app/* 请求转发到本地 dsh web Host（本文件 forwardWebRequest）
 *   3) 把 dsh-app://shell/* 请求落到壳自带的静态资源（serveWebDocument）
 *
 * 与官方的差异：官方用 desktop-host 注入的 authenticatedUrl（一次性令牌路径），
 * 薄壳改用 `dsh web --trusted-host 127.0.0.1`，让 Host 的 /api 信任围栏直接接受
 * 本机回环——对单用户桌面场景功能等价，且不需要额外编译 desktop-host 包。
 */

import { readFile } from 'node:fs/promises'
import { extname, resolve, sep } from 'node:path'

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.json': 'application/json',
  '.woff2': 'font/woff2', '.png': 'image/png', '.ico': 'image/x-icon',
}
const BOOT = '<script>globalThis.__DSH_BOOT_READY__ = Promise.withResolvers()</script>'

/** 壳自带静态资源（dsh-app://shell/）。 */
export async function serveWebDocument(request, root) {
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405 })
  const url = new URL(request.url)
  let pathname
  try { pathname = decodeURIComponent(url.pathname) } catch { return new Response(null, { status: 400 }) }
  const target = resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname))
  const directory = resolve(root)
  if (!target.startsWith(directory + sep)) return new Response(null, { status: 403 })
  let body
  try { body = await readFile(target) } catch (error) {
    if (error.code === 'ENOENT') return new Response(null, { status: 404 })
    throw error
  }
  const content = pathname === '/' || pathname === '/index.html'
    ? body.toString().replace('<head>', '<head>' + BOOT) : new Uint8Array(body)
  return new Response(request.method === 'HEAD' ? null : content, {
    headers: { 'content-type': MIME[extname(target)] ?? 'application/octet-stream' },
  })
}

/** 转发 dsh-app://app/* 到已认证的本地 Host，保留流式与取消。 */
export async function forwardWebRequest(request, host, cookie) {
  const source = new URL(request.url)
  const origin = request.headers.get('origin')
  if (origin !== null && origin !== 'dsh-app://app') return new Response(null, { status: 403 })
  const target = new URL(host)
  target.pathname = source.pathname
  target.search = source.search
  const headers = new Headers(request.headers)
  for (const name of ['host', 'origin', 'cookie', 'sec-fetch-site']) headers.delete(name)
  if (cookie) headers.set('cookie', cookie)
  const init = {
    method: request.method, headers, body: request.body,
    signal: request.signal, duplex: 'half', redirect: 'manual',
  }
  const response = await fetch(target, init)
  const outgoing = new Headers(response.headers)
  for (const name of ['set-cookie', 'content-encoding', 'content-length', 'transfer-encoding',
    'connection', 'keep-alive', 'te', 'trailer', 'upgrade', 'proxy-authenticate', 'proxy-authorization']) {
    outgoing.delete(name)
  }
  if (/^\/plugins\//u.test(source.pathname)) outgoing.set('cache-control', 'no-store')
  return new Response(response.body, { status: response.status, headers: outgoing })
}
