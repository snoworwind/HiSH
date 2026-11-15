import { hilog } from '@kit.PerformanceAnalysisKit'
import QemuAgent from './QemuAgent'
import appOption from '../model/appOption'
import napi from 'libhish_main.so'

const DOMAIN = 0x0000

// 队列配置
const MAX_QUEUE_SIZE = 3           // 队列最大长度
const ENABLE_DEDUP = true          // 启用去重（同组件只保留最新请求）

// 连接请求优先级
export enum AgentPriority {
  LOW = 0,      // 后台监控（VmStatusBar）
  NORMAL = 1,   // 普通操作
  HIGH = 2      // 用户操作（PowerManagement）
}

// 连接请求
interface ConnectionRequest {
  userId: string
  priority: AgentPriority
  resolve: (agent: QemuAgent | null) => void
  reject: (error: Error) => void
  timestamp: number
}

// 连接状态
interface ManagerStatus {
  currentUser: string | null
  queueLength: number
  isConnected: boolean
}

// xterm 的字符网格尺寸（columns x rows）
export interface TerminalSize {
  cols: number
  rows: number
}

// 终端尺寸同步的虚拟使用者标识
const TERMINAL_USER = 'terminal-size'
// 尺寸下发失败（QGA 未就绪 / 被其它组件占用）时的重试间隔与次数
const TERMINAL_SIZE_RETRY_MS = 2000
const TERMINAL_SIZE_MAX_ATTEMPTS = 6

/**
 * QemuAgent 连接管理器（单例）
 * 统一管理 QGA Socket 连接，避免多组件同时访问导致的竞争问题
 */
class QemuAgentManagerImpl {
  private static instance: QemuAgentManagerImpl | null = null

  private agent: QemuAgent | null = null
  private currentUser: string | null = null
  private waitQueue: ConnectionRequest[] = []
  private isProcessing: boolean = false
  private keepAliveTimer: number = -1

  // 待下发的终端尺寸：启动早期 QGA 可能还没就绪，先记住最新值，连上后补发
  private pendingTerminalSize: TerminalSize | null = null
  private terminalSizeTimer: number = -1
  private terminalSizeAttempts: number = 0
  private terminalSizeFlushing: boolean = false
  // 是否正在建立连接：避免终端尺寸同步与其它组件并发创建连接、互相 disconnect
  private connecting: boolean = false

  private constructor() { }

  static getInstance(): QemuAgentManagerImpl {
    if (!QemuAgentManagerImpl.instance) {
      QemuAgentManagerImpl.instance = new QemuAgentManagerImpl()
    }
    return QemuAgentManagerImpl.instance
  }

  /**
   * 获取 Agent 连接
   * @param userId 使用者标识
   * @param priority 优先级，默认 NORMAL
   * @param timeout 超时时间（毫秒），默认 5000
   */
  async acquire(userId: string, priority: AgentPriority = AgentPriority.NORMAL, timeout: number = 5000): Promise<QemuAgent | null> {
    hilog.info(DOMAIN, 'AgentManager', '请求连接: %{public}s, 优先级: %{public}d', userId, priority)

    // 如果当前没有使用者，直接获取
    if (!this.currentUser) {
      return await this.createConnection(userId)
    }

    // 如果是同一个使用者，直接返回现有连接
    if (this.currentUser === userId && this.agent) {
      // [修复] 即使是同一用户，也要检查 Agent 是否真的存活（防止 Socket 已断开但逻辑状态未更新）
      if (this.agent.isAlive()) {
        hilog.info(DOMAIN, 'AgentManager', '用户 %{public}s 复用现有活跃 Agent', userId);
        return this.agent;
      }
      hilog.warn(DOMAIN, 'AgentManager', '用户 %{public}s 的 Agent 已失效，准备释放并重新创建', userId);
      await this.forceRelease();
      // [修复] 释放后管理器变为空忙，直接重新连接，不要去排队
      return await this.createConnection(userId);
    }

    // 高优先级请求可以抢占低优先级
    if (priority === AgentPriority.HIGH && this.currentUser !== userId) {
      hilog.info(DOMAIN, 'AgentManager', '高优先级请求，要求 %{public}s 释放连接', this.currentUser)
      await this.forceRelease()
      return await this.createConnection(userId)
    }

    // 否则加入等待队列
    return new Promise<QemuAgent | null>((resolve: (agent: QemuAgent | null) => void, reject: (error: Error) => void) => {
      // 去重：移除同一用户的旧请求
      if (ENABLE_DEDUP) {
        const existingIndex = this.waitQueue.findIndex((r: ConnectionRequest) => r.userId === userId)
        if (existingIndex !== -1) {
          const oldRequest = this.waitQueue.splice(existingIndex, 1)[0]
          hilog.info(DOMAIN, 'AgentManager', '去重：移除 %{public}s 的旧请求', userId)
          oldRequest.resolve(null)  // 通知旧请求已取消
        }
      }

      // 队列满时拒绝新请求
      if (this.waitQueue.length >= MAX_QUEUE_SIZE) {
        hilog.warn(DOMAIN, 'AgentManager', '队列已满（%{public}d），拒绝 %{public}s', MAX_QUEUE_SIZE, userId)
        resolve(null)
        return
      }

      const request: ConnectionRequest = {
        userId,
        priority,
        resolve,
        reject,
        timestamp: Date.now()
      }

      // 按优先级插入队列
      let inserted = false
      for (let i = 0; i < this.waitQueue.length; i++) {
        if (this.waitQueue[i].priority < priority) {
          this.waitQueue.splice(i, 0, request)
          inserted = true
          break
        }
      }
      if (!inserted) {
        this.waitQueue.push(request)
      }

      hilog.info(DOMAIN, 'AgentManager', '%{public}s 加入等待队列，当前队列长度: %{public}d/%{public}d', userId, this.waitQueue.length, MAX_QUEUE_SIZE)

      // 设置超时
      setTimeout(() => {
        const index = this.waitQueue.findIndex((r: ConnectionRequest) => r.userId === userId && r.timestamp === request.timestamp)
        if (index !== -1) {
          this.waitQueue.splice(index, 1)
          hilog.warn(DOMAIN, 'AgentManager', '%{public}s 等待超时', userId)
          resolve(null)
        }
      }, timeout)
    })
  }

  /**
   * 释放连接
   * @param userId 使用者标识
   */
  async release(userId: string): Promise<void> {
    if (this.currentUser !== userId) {
      if (this.currentUser) {
        hilog.debug(DOMAIN, 'AgentManager', '忽略 %{public}s 的释放请求 (当前实际持有者: %{public}s)', userId, this.currentUser)
      }
      return
    }

    hilog.info(DOMAIN, 'AgentManager', '%{public}s 释放连接 (进入空闲复用状态)', userId)

    // 软释放：不关闭连接，只清除使用者标识
    // 这样下次 acquire 可以直接复用
    this.currentUser = null

    // 处理等待队列中的下一个请求
    await this.processQueue()
  }

  /**
   * 把 xterm 的当前字符网格尺寸同步到 guest 的串口 tty（/dev/ttyAMA0）。
   *
   * host 与 guest 之间只有 QEMU 的 socket chardev，没有 pty，guest 拿不到
   * TIOCSWINSZ。nvim / less / top 等全屏程序通过 TIOCGWINSZ 读取 tty 尺寸，
   * 尺寸过期的直接后果是换行与绝对光标定位错位（大量“排版错误”）。
   *
   * 这里用 QGA 在 guest 内执行 stty：TIOCSWINSZ 会让 guest 内核给该 tty 的
   * 前台进程组发 SIGWINCH，全屏程序随即按新尺寸重排；不会向输入流写任何字节，
   * 因此不会像直接注入 CSI 8 t 那样被 shell/zle 当成键盘输入。
   *
   * QGA 尚未就绪时会把尺寸记为 pending 并自动重试；返回 false 仅表示本次未下发。
   */
  async applyTerminalSize(cols: number, rows: number): Promise<boolean> {
    const c = Math.floor(cols)
    const r = Math.floor(rows)
    if (!(c >= 2 && c <= 1000 && r >= 1 && r <= 1000)) {
      hilog.warn(DOMAIN, 'AgentManager', '忽略非法终端尺寸: %{public}dx%{public}d', cols, rows)
      return false
    }

    const old = this.pendingTerminalSize
    const changed = old === null || old.cols !== c || old.rows !== r
    this.pendingTerminalSize = { cols: c, rows: r }
    if (changed) {
      // 尺寸变了就重置重试预算，保证新尺寸有机会下发
      this.terminalSizeAttempts = 0
    }

    const applied = await this.flushTerminalSize()
    if (!applied) {
      this.scheduleTerminalSizeRetry()
    }
    return applied
  }

  /**
   * 尝试把 pending 尺寸真正写进 guest；返回是否已无待下发尺寸。
   */
  private async flushTerminalSize(): Promise<boolean> {
    const size = this.pendingTerminalSize
    if (!size) {
      return true
    }
    // 已有下发流程在进行，或其它组件正占用 QGA / 正在建连：稍后重试，不消耗重试预算
    if (this.terminalSizeFlushing || this.currentUser || this.connecting) {
      return false
    }

    this.terminalSizeFlushing = true
    try {
      const agent = await this.acquire(TERMINAL_USER, AgentPriority.NORMAL, 1500)
      if (!agent) {
        this.terminalSizeAttempts++
        return false
      }

      // 等待连接期间 xterm 可能又变了，下发最新值
      const latest = this.pendingTerminalSize ?? size
      const cmd = `stty -F /dev/ttyAMA0 rows ${latest.rows} cols ${latest.cols}`
      try {
        const pid = await agent.exec('/bin/sh', ['-c', cmd])
        if (pid === null) {
          this.terminalSizeAttempts++
          hilog.warn(DOMAIN, 'AgentManager', '终端尺寸下发失败 (pid=null): %{public}s', cmd)
          return false
        }
        hilog.info(DOMAIN, 'AgentManager', '终端尺寸已同步到 guest: %{public}dx%{public}d', latest.cols, latest.rows)
        if (this.pendingTerminalSize === latest) {
          this.pendingTerminalSize = null
        }
        this.terminalSizeAttempts = 0
        return true
      } finally {
        await this.release(TERMINAL_USER)
      }
    } catch (e) {
      this.terminalSizeAttempts++
      hilog.warn(DOMAIN, 'AgentManager', '终端尺寸同步异常: %{public}s', JSON.stringify(e))
      return false
    } finally {
      this.terminalSizeFlushing = false
    }
  }

  /**
   * QGA 还不可用时安排一次重试（指数退避会拖得太久，这里固定间隔 + 次数上限）。
   */
  private scheduleTerminalSizeRetry(): void {
    if (this.terminalSizeTimer !== -1 || !this.pendingTerminalSize) {
      return
    }
    if (this.terminalSizeAttempts >= TERMINAL_SIZE_MAX_ATTEMPTS) {
      hilog.warn(DOMAIN, 'AgentManager', '终端尺寸同步重试次数用尽，等待下一次 resize 再试')
      return
    }
    this.terminalSizeTimer = setTimeout(() => {
      this.terminalSizeTimer = -1
      void this.flushTerminalSize().then((applied: boolean) => {
        if (!applied) {
          this.scheduleTerminalSizeRetry()
        }
      })
    }, TERMINAL_SIZE_RETRY_MS)
  }

  /**
   * QGA 刚就绪（新建或复用连接）：补发启动早期没能下发的终端尺寸。
   * 此刻连接被调用方占用，所以只安排一次稍后的重试。
   */
  private onAgentReady(): void {
    if (this.pendingTerminalSize) {
      this.terminalSizeAttempts = 0
      this.scheduleTerminalSizeRetry()
    }
  }

  /**
   * 强制释放当前连接（用于高优先级抢占或彻底清理）
   */
  private async forceRelease(): Promise<void> {
    hilog.info(DOMAIN, 'AgentManager', '强制释放并关闭连接，当前使用者: %{public}s', this.currentUser || 'none')

    if (this.agent) {
      try {
        await this.agent.disconnect()
      } catch (e) {
        // 忽略断开错误
      }
      this.agent = null
    }
    this.currentUser = null
    this.stopKeepAlive()

    // [修复] 强制释放后，唤醒等待队列，防止请求挂起
    await this.processQueue()
  }

  /**
   * 创建新连接
   */
  private async createConnection(userId: string): Promise<QemuAgent | null> {
    // 如果已有连接且可用，直接复用
    if (this.agent && this.agent.isAlive()) {
      hilog.info(DOMAIN, 'AgentManager', '复用现有空闲连接: %{public}s', userId)
      this.currentUser = userId
      this.onAgentReady()
      return this.agent
    }

    const appTempDir = AppStorage.get(appOption.appTempDir) as string
    if (!appTempDir) {
      hilog.error(DOMAIN, 'AgentManager', 'appTempDir 未设置')
      return null
    }

    // 同一时间只允许一个连接在建立：并发 connect 会互相 disconnect，导致双方都失败
    if (this.connecting) {
      hilog.info(DOMAIN, 'AgentManager', '已有连接正在建立，%{public}s 稍后重试', userId)
      return null
    }
    this.connecting = true

    const qgaSocket = appTempDir + '/qga_socket'

    try {
      // 彻底清理旧连接
      if (this.agent) {
        await this.agent.disconnect()
      }

      this.agent = new QemuAgent(qgaSocket)
      const connected = await this.agent.connect()

      if (connected) {
        this.currentUser = userId
        hilog.info(DOMAIN, 'AgentManager', '%{public}s 连接成功', userId)

        // 启动心跳保活
        this.startKeepAlive()
        this.onAgentReady()

        return this.agent
      } else {
        this.agent = null
        hilog.error(DOMAIN, 'AgentManager', '%{public}s 连接失败', userId)
        return null
      }
    } catch (e) {
      this.agent = null
      hilog.error(DOMAIN, 'AgentManager', '创建连接失败: %{public}s', JSON.stringify(e))
      return null
    } finally {
      this.connecting = false
    }
  }

  /**
   * 启动心跳保活
   */
  private startKeepAlive(): void {
    this.stopKeepAlive()

    hilog.info(DOMAIN, 'AgentManager', '启动 QGA 心跳保活 (20s)')
    this.keepAliveTimer = setInterval(async () => {
      const currentAgent = this.agent

      if (!currentAgent || !currentAgent.isAlive()) {
        this.stopKeepAlive()
        return
      }

      // [修复] 如果当前有使用者正在操作，不要发送心跳 ping，防止 pendingResponse 被清空导致业务指令超时
      if (this.currentUser) {
        hilog.debug(DOMAIN, 'AgentManager', '业务正在占用 Agent，跳过此轮心跳')
        return
      }

      try {
        hilog.debug(DOMAIN, 'AgentManager', '发送 QGA 心跳 (ping)...')
        const success = await currentAgent.ping()

        if (!success) {
          hilog.warn(DOMAIN, 'AgentManager', 'QGA 心跳失败，尝试自动重连...')
          // P1-10修复: 心跳失败后尝试自动重连一次
          const reconnected = await currentAgent.connect()
          if (reconnected) {
            hilog.info(DOMAIN, 'AgentManager', 'QGA 自动重连成功')
          } else {
            hilog.error(DOMAIN, 'AgentManager', 'QGA 自动重连失败，清理连接')
            await this.forceRelease()
          }
        }
      } catch (e) {
        hilog.error(DOMAIN, 'AgentManager', '心跳执行异常: %{public}s', JSON.stringify(e))
      }
    }, 20000) // 20秒一次心跳
  }

  /**
   * 停止心跳保活
   */
  private stopKeepAlive(): void {
    if (this.keepAliveTimer !== -1) {
      clearInterval(this.keepAliveTimer)
      this.keepAliveTimer = -1
      hilog.info(DOMAIN, 'AgentManager', '停止 QGA 心跳保活')
    }
  }

  /**
   * 处理等待队列
   */
  private async processQueue(): Promise<void> {
    if (this.isProcessing || this.waitQueue.length === 0 || this.currentUser) {
      return
    }

    this.isProcessing = true

    try {
      // 循环处理，直到有用户成功连接或队列为空
      while (this.waitQueue.length > 0 && !this.currentUser) {
        const request = this.waitQueue.shift()
        if (request) {
          hilog.info(DOMAIN, 'AgentManager', '处理队列请求: %{public}s', request.userId)
          const agent = await this.createConnection(request.userId)

          if (agent) {
            // 连接成功，currentUser 已在 createConnection 中设置
            request.resolve(agent)
            // 循环结束，currentUser 不为空
          } else {
            // 连接失败，继续处理下一个请求
            hilog.warn(DOMAIN, 'AgentManager', '%{public}s 连接失败，尝试下一个请求', request.userId)
            request.resolve(null)
          }
        }
      }
    } finally {
      this.isProcessing = false

      // 如果还有等待的请求且当前无用户，继续尝试（递归保护）
      if (this.waitQueue.length > 0 && !this.currentUser && !this.isProcessing) {
        this.processQueue()
      }
    }
  }

  /**
   * 获取当前连接状态
   */
  getStatus(): ManagerStatus {
    const status: ManagerStatus = {
      currentUser: this.currentUser,
      queueLength: this.waitQueue.length,
      isConnected: this.agent !== null && this.agent.isAlive()
    }
    return status
  }
}

// 导出单例
export const QemuAgentManager = QemuAgentManagerImpl.getInstance()
export default QemuAgentManager
