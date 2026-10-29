import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BackgroundTaskItem, BackgroundTasksState } from '../types'

/** 面板的 id，也是 `ui.render` 的 requestId 和 `/background-tasks` 命令打开的那一个。 */
const PANE_ID = 'background-tasks'

/** status.sh 在仓库根目录执行，argv 形式、无 shell。 */
const STATUS_SCRIPT = 'Tools/agents/status.sh'
const REPO_ROOT = '/Users/zyx/Documents/GPXPointViewer'

/** 面板读的唯一状态；键在 types/index.d.ts 的 PluginState 契约里声明。 */
const snapshot = atom(
  { plugin: 'background-tasks', key: 'snapshot' } as const,
  {
    status: 'ok',
    time: '',
    running: 0,
    ledgerUsd: '0',
    items: [],
  } as BackgroundTasksState,
)

/** 把任意文字压成一行（错误只在面板里占一行），过长就截断。 */
function oneLine(value: string): string {
  const line = value.replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim()
  return line.length > 160 ? `${line.slice(0, 157)}…` : line
}

function asText(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

/** 把 status.sh --json 的一行 JSON 读成快照；形状不对就抛错，由 refresh 换成 error。 */
function parseSnapshot(stdout: string): BackgroundTasksState {
  let data: unknown
  try {
    data = JSON.parse(stdout)
  } catch {
    throw new Error('status.sh 的输出不是有效 JSON')
  }
  if (typeof data !== 'object' || data === null) {
    throw new Error('status.sh 的输出不是 JSON 对象')
  }

  const raw = data as Record<string, unknown>
  if (!Array.isArray(raw.items)) {
    throw new Error('status.sh 的输出缺少 items 数组')
  }

  const items: BackgroundTaskItem[] = raw.items.map((entry, index) => {
    if (typeof entry !== 'object' || entry === null) {
      throw new Error(`status.sh 的第 ${index + 1} 个 item 不是对象`)
    }
    const item = entry as Record<string, unknown>
    return {
      kind: asText(item.kind) ?? '未知类型',
      name: asText(item.name) ?? '未知名字',
      since: asText(item.since) ?? '',
      detail: asText(item.detail) ?? '',
      // aux:true 的是附带活动——列出来但不计入任务数。
      aux: item.aux === true,
    }
  })

  const ledger = raw.ledger_usd
  return {
    status: 'ok',
    time: asText(raw.time) ?? '',
    // 不信 JSON 里的 running 字段，按 aux 现算：aux 永远不进 N。
    running: items.filter(item => !item.aux).length,
    ledgerUsd:
      typeof ledger === 'number' && Number.isFinite(ledger)
        ? String(ledger)
        : asText(ledger) ?? '0',
    items,
  }
}

/**
 * 跑一次 status.sh --json，把快照（或一行错误）写进 atom。永不抛：
 * 退出码非 0、JSON 坏了、进程起不来，都变成 `{ status: 'error', error }`。
 */
async function refresh($: EngineInterface): Promise<void> {
  let next: BackgroundTasksState
  try {
    const result = await $.process.run([STATUS_SCRIPT, '--json'], {
      cwd: REPO_ROOT,
      timeoutMs: 15000,
    })
    if (result.exitCode !== 0) {
      const reason = oneLine(result.stderr)
      throw new Error(
        `status.sh 退出码 ${result.exitCode}${reason === '' ? '' : `：${reason}`}`,
      )
    }
    next = parseSnapshot(result.stdout)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    next = { status: 'error', error: oneLine(message) || '未知错误' }
  }

  try {
    await update($, snapshot, () => next)
  } catch {
    // 状态写不进去也不让定时器抛出去；下一轮刷新再试，面板保留上一次的画面。
  }
}

/** 任务/附带活动共用的一行：类型 · 名字 · 从 HH:MM 开始 · 详情。 */
function itemLine(item: BackgroundTaskItem): string {
  return `${item.kind} · ${item.name} · 从 ${item.since} 开始 · ${item.detail}`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'background-tasks',
      description: '后台任务面板：显示现在有几个任务在跑（每 10 秒自动刷新）',
    })

    // 立即刷新一次，面板第一帧就有数。
    await refresh($)

    // 每 10 秒刷新：要改间隔就改这一行的 10000（毫秒）。
    $.clock.every(10000, () => {
      void refresh($)
    })

    try {
      await $.ui.open({ id: PANE_ID, title: '后台任务' })
    } catch {
      // 打不开也不能让 session.start 失败；用户可用 /background-tasks 再开。
    }

    return next(e)
  })

  on('command.run', { command: 'background-tasks' }, async $ => {
    // 先刷新再开，关掉面板后再打开时手里是新的数。
    await refresh($)
    await $.ui.open({ id: PANE_ID, title: '后台任务' })
    return { text: '后台任务面板已打开，每 10 秒自动刷新。' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE_ID }, async ($, e) => {
    // 只用 Box / Text 两种元素；terminal 和 desktop 两种表面画同一棵树。
    const { Box, Text } = $.ui.resolve(e)
    const state = await read($, snapshot)
    const tasks = state.status === 'ok' ? state.items.filter(item => !item.aux) : []
    const aux = state.status === 'ok' ? state.items.filter(item => item.aux) : []
    const headline =
      state.status === 'ok'
        ? state.running === 0
          ? '现在没有任务在跑'
          : `现在有 ${state.running} 个任务在跑`
        : ''

    return (
      <Box flexDirection="column">
        {state.status === 'error' && <Text color="error">读取失败：{state.error}</Text>}

        {state.status === 'ok' && (
          <Text bold size="heading">
            {headline}
            {state.time === '' ? '' : ` · ${state.time}`}
          </Text>
        )}

        {state.status === 'ok' && tasks.map(item => <Text>{itemLine(item)}</Text>)}

        {state.status === 'ok' && tasks.length === 0 && <Text dimColor>—</Text>}

        {state.status === 'ok' &&
          aux.map(item => <Text dimColor>附带：{itemLine(item)}</Text>)}

        {state.status === 'ok' && (
          <Text dimColor>Claude API 台账合计 {state.ledgerUsd} 美元</Text>
        )}
      </Box>
    )
  })
}
