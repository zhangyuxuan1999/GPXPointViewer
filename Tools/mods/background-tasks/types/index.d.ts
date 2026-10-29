/**
 * 面板状态的契约：`$.state` 里 `background-tasks` 插件只有一个键 `snapshot`，
 * 要么是 status.sh --json 解析出来的快照，要么是一行错误文字。
 */

/** status.sh --json 的一个 item；aux 为 true 的是构建/测试副本/脚本这类附带活动。 */
export type BackgroundTaskItem = {
  /** 类型，例如「Claude API 任务」「xcodebuild 构建」。 */
  kind: string
  /** 名字，例如任务目录名或进程名。 */
  name: string
  /** 开始时间 HH:MM。 */
  since: string
  /** 详情，一行。 */
  detail: string
  /** 附带活动：列在任务下面，不计入「现在有 N 个任务在跑」。 */
  aux: boolean
}

/** 一次刷新的结果：成功快照，或一行可直接显示的读取错误。 */
export type BackgroundTasksState =
  | {
      status: 'ok'
      /** status.sh 给出的 HH:MM:SS。 */
      time: string
      /** 正在跑的任务数（已排除 aux 项）。 */
      running: number
      /** Claude API 台账合计，美元，展示用字符串。 */
      ledgerUsd: string
      /** 全部 item，含 aux 项。 */
      items: BackgroundTaskItem[]
    }
  | {
      status: 'error'
      /** 一行错误文字，面板显示为「读取失败：…」。 */
      error: string
    }

declare module 'claude-code' {
  interface PluginState {
    'background-tasks': { snapshot: BackgroundTasksState }
  }
}
