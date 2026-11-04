#!/usr/bin/env node
/**
 * 把已搬迁到 E:\工作区\GitHub日报 的会话登记进「GitHub日报」工作区。
 *
 * 背景：DSH 的会话归属 = 工作区记录里的 sessionIds ∩ 会话头 cwd 匹配工作区路径，
 * 而宿主只在「首次初始化」时按目录自动收编老会话；之后即使目录已经对上，
 * 也不会自动进组。所以必须在 DSH 关闭时把 id 预先写进注册表。
 * 若 DSH 正在运行，宿主内存里的旧注册表会在它下次写盘时覆盖本次写入。
 *
 * 本脚本幂等：已登记则只做清理与报告。
 * 用法：node relink-session.js [--force]
 */
const fs = require('node:fs')
const path = require('node:path')
const zlib = require('node:zlib')
const crypto = require('node:crypto')
const { execSync } = require('node:child_process')

const DSH = path.join(process.env.USERPROFILE || 'C:\\Users\\kalekaler', '.dsh')
const SESSION_ID = 'session-45c9d71f-05a3-40b8-89be-269c1f8bd390'
const TITLE = '我想做一个帮我每天查看GitHub'
const NEW_CWD = 'E:\\工作区\\GitHub日报'
const WS_ID = '4ab584ae-fc1e-4819-b8ef-9097d2cc5888'
const MAGIC = 4247762216

const say = (s) => process.stdout.write(s + '\n')
const sleep = (ms) => { const end = Date.now() + ms; while (Date.now() < end) { /* spin */ } }

function encodeSegment(value) {
  let out = ''
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i)
    const ch = String.fromCharCode(code)
    out += /^[A-Za-z0-9._-]$/.test(ch) ? ch : '~' + code.toString(16).toUpperCase().padStart(4, '0')
  }
  return out
}
function projectKey(cwd) {
  let readable = ''
  let separatorRun = false
  for (let i = 0; i < cwd.length; i++) {
    const code = cwd.charCodeAt(i)
    const ch = String.fromCharCode(code)
    if (ch === '/' || ch === '\\' || ch === ':') { if (!separatorRun) readable += '-'; separatorRun = true }
    else if (ch !== '~' && /^[A-Za-z0-9._-]$/.test(ch)) { readable += ch; separatorRun = false }
    else { readable += '~' + code.toString(16).toUpperCase().padStart(4, '0'); separatorRun = false }
  }
  return `--${(readable.replace(/^-+/, '') || 'root').slice(0, 251)}--`
}
function firstFrame(buf) {
  if (buf.readUInt32LE(0) !== MAGIC) throw new Error('not a zstd frame')
  const fhd = buf[4]
  const fcsFlag = (fhd >> 6) & 3, single = (fhd >> 5) & 1, checksum = (fhd >> 2) & 1, dictId = fhd & 3
  let pos = 5
  if (single === 0) pos += 1
  pos += [0, 1, 2, 4][dictId]
  pos += [single ? 1 : 0, 2, 4, 8][fcsFlag]
  for (;;) {
    const b0 = buf[pos], b1 = buf[pos + 1], b2 = buf[pos + 2]
    const last = b0 & 1, type = (b0 >> 1) & 3, size = (b0 >> 3) | (b1 << 5) | (b2 << 13)
    pos += 3
    pos += type === 1 ? 1 : size
    if (last) break
  }
  if (checksum) pos += 4
  return zlib.zstdDecompressSync(buf.subarray(0, pos)).toString('utf8')
}
function dshDesktopRunning() {
  try {
    const out = execSync('tasklist /FI "IMAGENAME eq DSH Desktop.exe" /NH', { encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'] })
    if (/DSH Desktop\.exe/i.test(out)) return true
    return false
  } catch {
    return null // 无法判定（例如受限环境下 tasklist 不可用）
  }
}

const force = process.argv.includes('--force')
say('== relink-session : 「' + TITLE + '」-> GitHub日报 ==')
say('DSH_HOME = ' + DSH)

// 0. 前置：会话文件确实已在目标位置，且头里的 cwd 正确
const logPath = path.join(DSH, 'sessions', projectKey(NEW_CWD), encodeSegment(SESSION_ID), 'session.v4.jsonl.zstd')
if (!fs.existsSync(logPath)) { say('[x] 中止：目标位置找不到会话日志\n    ' + logPath); process.exit(2) }
const header = JSON.parse(firstFrame(fs.readFileSync(logPath)).split('\n')[0])
if (header.id !== SESSION_ID) { say('[x] 中止：日志头 id 不符：' + header.id); process.exit(2) }
if (header.cwd !== NEW_CWD) { say('[x] 中止：日志头 cwd 不是目标工作区：' + header.cwd); process.exit(2) }
say('[ok] 会话日志已就位，头 cwd = ' + header.cwd)

// 1. 宿主是否在运行
const running = dshDesktopRunning()
if (running === true && !force) {
  say('')
  say('[!] 检测到 DSH Desktop 正在运行，拒绝写入。')
  say('    宿主内存里保存着旧注册表，现在写入会在它下次写盘时被覆盖。')
  say('    请完全退出 DSH Desktop 后再运行。')
  process.exit(3)
}
if (running === null) say('[i] 无法自动检测 DSH 是否在运行（tasklist 不可用），请自行确认它已完全退出。')
else if (running === true) say('[i] --force：跳过「DSH 正在运行」检查。')
else say('[ok] 未检测到 DSH Desktop 进程。')

// 2. 读并改注册表
const wsPath = path.join(DSH, 'storages', 'workspace.json')
const wsText = fs.readFileSync(wsPath, 'utf8')
const ws = JSON.parse(wsText)
if (JSON.stringify(ws, null, 2) + '\n' !== wsText) { say('[x] 中止：workspace.json 格式与预期不符，拒绝重写'); process.exit(2) }
const record = ws.tables.workspaces[WS_ID]
if (!record) { say('[x] 中止：找不到 GitHub日报 工作区记录 ' + WS_ID); process.exit(2) }
if (record.path !== NEW_CWD) { say('[x] 中止：工作区路径不是 ' + NEW_CWD + '，实际是 ' + record.path); process.exit(2) }

const already = record.sessionIds.includes(SESSION_ID)
if (already) {
  say('[ok] 注册表里已经有这个会话，无需修改。')
} else {
  const bkDir = path.join(DSH, '_move-backup-' + new Date().toISOString().replace(/[:.]/g, '-'))
  fs.mkdirSync(bkDir, { recursive: true })
  fs.copyFileSync(wsPath, path.join(bkDir, 'workspace.json'))
  say('[ok] 已备份 workspace.json -> ' + bkDir)

  record.sessionIds = [SESSION_ID, ...record.sessionIds]
  record.updatedAt = new Date().toISOString()
  const tmp = wsPath + '.relink.tmp'
  fs.writeFileSync(tmp, JSON.stringify(ws, null, 2) + '\n', 'utf8')
  fs.renameSync(tmp, wsPath)
  say('[ok] 已登记进「GitHub日报」，sessionIds 现在为：')
  for (const id of record.sessionIds) say('       ' + (id === SESSION_ID ? '* ' : '  ') + id)
}

// 3. 清理可能被宿主重建的过期投影缓存（里面记着旧 cwd）
const projCache = path.join(DSH, 'storages', 'session_projcache', 'sessions', SESSION_ID + '.json')
if (fs.existsSync(projCache)) {
  let stale = ''
  try { stale = JSON.parse(fs.readFileSync(projCache, 'utf8')).record.identity.cwd } catch {}
  fs.rmSync(projCache)
  say('[ok] 已删除投影缓存（原记录 cwd = ' + stale + '），下次启动按新 cwd 重建')
} else say('[ok] 无过期投影缓存')

// 4. 写后 1.2 秒回读：若被宿主覆盖，这里能看出来
sleep(1200)
const after = JSON.parse(fs.readFileSync(wsPath, 'utf8'))
const list = after.tables.workspaces[WS_ID].sessionIds
const survives = list.includes(SESSION_ID)
say('')
say('== 完成 ==')
say('GitHub日报 含该会话：' + survives + '（位置 #' + (list.indexOf(SESSION_ID) + 1) + ' / 共 ' + list.length + '）')
say('sha256(workspace.json) = ' + crypto.createHash('sha256').update(fs.readFileSync(wsPath)).digest('hex').slice(0, 16) + '…')
if (!survives) {
  say('')
  say('[!] 写入后回读发现条目已消失 —— DSH 很可能仍在运行并覆盖了注册表。')
  say('    请完全退出 DSH Desktop，然后重新运行本脚本。')
  process.exit(4)
}
say('现在重新打开 DSH Desktop，该会话应出现在侧边栏「GitHub日报」分组下。')
