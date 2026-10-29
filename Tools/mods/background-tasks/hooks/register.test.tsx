import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'background-tasks',
  component: 'Pane',
  requestId: 'background-tasks',
  props: {
    title: '后台任务',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

/** `$.process.run` 的底：除了 stdout 之外的字段都取 status.sh 正常退出时的样子。 */
const RUN_BASE = {
  exitCode: 0,
  stdout: '',
  stderr: '',
  isStdoutTruncated: false,
  isStderrTruncated: false,
}

/** 让 status.sh 的调用返回一段假 JSON——测试里不起任何进程。 */
function runPrinting(payload: unknown) {
  return () => ({ value: { ...RUN_BASE, stdout: JSON.stringify(payload) } })
}

test('两个任务：标题与两行任务在终端和桌面上都能画出', async ($, on) => {
  mock.clock(on)
  on('command.register', () => ({ value: { command: 'background-tasks' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on(
    'process.run',
    runPrinting({
      time: '17:47:29',
      running: 2,
      ledger_usd: 92.09,
      items: [
        {
          kind: 'Claude API 任务',
          name: 'map-sources',
          since: '16:21',
          detail: '最后活动 16:59 · 记录 20261026_162124_map-sources',
          aux: false,
        },
        {
          kind: 'DeepSeek 测试',
          name: 'status_mod_v3',
          since: '17:01',
          detail: '进程 4321',
          aux: false,
        },
      ],
    }),
  )

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })

    const headline = await ui.find({ type: 'Text', text: /现在有 2 个任务在跑/ })
    expect(headline?.text).toContain('现在有 2 个任务在跑')
    expect(headline?.text).toContain('17:47:29')

    const rows = await ui.findAll({ type: 'Text', text: /· 从 (16:21|17:01) 开始 ·/ })
    expect(rows).toHaveLength(2)
    expect(rows[0]?.text).toBe(
      'Claude API 任务 · map-sources · 从 16:21 开始 · 最后活动 16:59 · 记录 20261026_162124_map-sources',
    )
    expect(rows[1]?.text).toBe('DeepSeek 测试 · status_mod_v3 · 从 17:01 开始 · 进程 4321')

    expect(
      (await ui.find({ type: 'Text', text: /Claude API 台账合计 92\.09 美元/ }))?.text,
    ).toBe('Claude API 台账合计 92.09 美元')

    await ui.unmount()
  }
})

test('命令失败时画面显示读取失败，不崩也不空白', async ($, on) => {
  mock.clock(on)
  on('command.register', () => ({ value: { command: 'background-tasks' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', () => ({
    value: { ...RUN_BASE, exitCode: 1, stderr: 'boom: status.sh 起不来\n' },
  }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const line = await ui.find({ type: 'Text', text: /读取失败：/ })
  expect(line?.text).toContain('读取失败：')
  expect(line?.text).toContain('退出码 1')
  await ui.unmount()
})

test('JSON 解析失败也显示读取失败', async ($, on) => {
  mock.clock(on)
  on('command.register', () => ({ value: { command: 'background-tasks' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', () => ({ value: { ...RUN_BASE, stdout: '这不是 JSON' } }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const line = await ui.find({ type: 'Text', text: /读取失败：/ })
  expect(line?.text).toContain('读取失败：')
  expect(line?.text).toContain('不是有效 JSON')
  await ui.unmount()
})

test('aux 项不计入任务数，列在任务下面并变暗', async ($, on) => {
  mock.clock(on)
  on('command.register', () => ({ value: { command: 'background-tasks' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on(
    'process.run',
    runPrinting({
      time: '18:00:01',
      ledger_usd: '0',
      items: [
        {
          kind: 'Claude API 任务',
          name: 'map-sources',
          since: '16:21',
          detail: '最后活动 16:59',
          aux: false,
        },
        {
          kind: 'xcodebuild 构建',
          name: 'Release',
          since: '17:49',
          detail: '进程 70384',
          aux: true,
        },
      ],
    }),
  )

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  // 两条 item、一条 aux：N 必须是 1（running 字段缺席时按 aux 现算）。
  expect((await ui.find({ type: 'Text', text: /现在有 1 个任务在跑/ }))?.text).toContain(
    '现在有 1 个任务在跑',
  )
  expect(await ui.find({ type: 'Text', text: /现在有 2 个任务在跑/ })).toBeUndefined()

  const auxLine = await ui.find({ type: 'Text', text: /附带：xcodebuild 构建/ })
  expect(auxLine?.text).toBe('附带：xcodebuild 构建 · Release · 从 17:49 开始 · 进程 70384')
  expect(auxLine?.props.dimColor).toBe(true)

  await ui.unmount()
})

test('每 10 秒定时刷新，画面跟着变', async ($, on) => {
  const clock = mock.clock(on)
  on('command.register', () => ({ value: { command: 'background-tasks' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  let payload: unknown = { time: '18:10:00', running: 0, ledger_usd: 0, items: [] }
  on('process.run', () => ({ value: { ...RUN_BASE, stdout: JSON.stringify(payload) } }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /现在没有任务在跑/ }))?.text).toContain(
    '现在没有任务在跑',
  )

  payload = {
    time: '18:10:10',
    running: 1,
    ledger_usd: 92.09,
    items: [
      {
        kind: 'DeepSeek 测试',
        name: 'status_mod_v3',
        since: '18:10',
        detail: '进程 1',
        aux: false,
      },
    ],
  }
  await clock.advance(10000)

  // 状态写入会重画已挂载的 Pane（读订阅），不用重新 mount。
  expect((await ui.find({ type: 'Text', text: /现在有 1 个任务在跑/ }))?.text).toContain(
    '现在有 1 个任务在跑',
  )
  expect((await ui.find({ type: 'Text', text: /18:10:10/ }))?.text).toContain('18:10:10')
  expect((await ui.find({ type: 'Text', text: /DeepSeek 测试 · status_mod_v3/ }))?.text).toBe(
    'DeepSeek 测试 · status_mod_v3 · 从 18:10 开始 · 进程 1',
  )
  await ui.unmount()
})

test('没有任务时显示「现在没有任务在跑」、破折号和台账', async ($, on) => {
  mock.clock(on)
  on('command.register', () => ({ value: { command: 'background-tasks' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on(
    'process.run',
    runPrinting({ time: '18:01:02', running: 0, ledger_usd: 0, items: [] }),
  )

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /现在没有任务在跑/ }))?.text).toContain(
    '现在没有任务在跑',
  )
  expect((await ui.find({ type: 'Text', text: '—' }))?.text).toBe('—')
  expect((await ui.find({ type: 'Text', text: /Claude API 台账合计 0 美元/ }))?.text).toBe(
    'Claude API 台账合计 0 美元',
  )
  await ui.unmount()
})
