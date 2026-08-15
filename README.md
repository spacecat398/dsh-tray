# dsh-tray

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

把仓库地址给你的 dsh-agent，你除了复制粘贴以外不需要做任何事情。

---

欢迎你，Agent 👋

这个仓库是一个 Windows 托盘程序：**DeepSeek Harness（dsh web）的常驻开关 + 看门狗**。托盘负责启动 / 重启 / 停止 dsh web、健康监控、崩溃自动拉起，还带"开启新对话"和日志复制。菜单语言跟随系统（中文 / English），一切参数通过 `dsh-tray.json` 配置。

下面的**协议**是给你（安装 / 配置 / 运维它的 Agent）看的操作契约。请先读完协议再动手，尤其是**安全规则**和**完成检查**。

---

## 📜 给 Agent 的协议（Agent Protocol）

本协议适用于安装、配置、启动、验证 dsh-tray 的 AI Agent。

### 1. Objective

在一台 Windows 机器上把 dsh-tray 部署为常驻托盘程序：开机自启、托盘控制 dsh web（默认端口 3080）、崩溃自动拉起。优先最小可用配置，不要引入额外依赖。

### 2. Requirements

- Windows 10/11（自带 PowerShell 5.1+，程序依赖 `powershell.exe`，不是 pwsh）
- Node.js 全局安装 dsh：`npm i -g @deepseek-ai/dsh`，且 `dsh web` 能启动
- 本仓库已克隆到目标机器（例如 `C:\dsh-tray\`）

### 3. Install

```powershell
# 1. 克隆（如尚未克隆）
git clone https://github.com/spacecat398/dsh-tray.git
# 2. 复制配置模板
Copy-Item dsh-tray.example.json dsh-tray.json
# 3. 按需编辑 dsh-tray.json（至少确认 startscript 指向一个能启动 dsh web 的脚本）
# 4. 启动托盘
wscript //nologo dsh-tray-launch.vbs
```

零依赖：纯 PowerShell + WinForms，不需要 npm install / pip / Docker。

### 4. Configure（dsh-tray.json）

| 键 | 默认 | 说明 |
|---|---|---|
| `port` | `3080` | dsh web 端口。**3080 是 dsh 的开箱默认端口**（官方 README 与 web-app 包内补丁均为 `?? 3080`）；healthurl/dashboardurl 由它派生 |
| `startscript` | `start-dsh.cmd` | 启动脚本；托盘以 `<port>` 作为 %1 调用它 |
| `dshlogfile` | `logs\dsh-web.log` | "复制最近日志"菜单读取的文件 |
| `healthintervalseconds` | `10` | 健康检查间隔（秒） |
| `startupgraceseconds` | `120` | 启动宽限期（期间只显示 Warming up） |
| `restartdelayseconds` | `5` | 崩溃重启基础延迟；退避上限 ×6 = 30s |
| `language` | `auto` | `auto`（跟随系统）/ `zh` / `en` |
| `notifications` | `true` | 状态跳变通知气泡开关 |
| `whaleicon` | `true` | 健康时使用鲸鱼图标（`assets\dsh-whale.png`） |

### 5. 运行与验证（Completion Check）

报告完成前，逐条核对：

1. `dsh-tray.ps1` 能被 Windows PowerShell 5.1 正常解析（**文件必须保存为 UTF-8 with BOM**，否则中文按 ANSI 解码直接语法崩溃）
2. 托盘进程在运行且**单实例**：
   ```powershell
   Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '-File.*dsh-tray\.ps1' }
   ```
3. 托盘菜单完整：状态行 / 打开面板 / 开启新对话 / 重启 dsh / 停止 dsh / 复制最近日志 / 开机自启（**没有 Exit 菜单项，这是设计**）
4. dsh web 健康：菜单状态行显示 `Healthy (:<port>)`，且 `Get-NetTCPConnection -LocalPort <port> -State Listen` 有监听（默认 3080）
5. 托盘日志 `logs\dsh-tray.log` 有 `Tray application starting ... v1.x.x` 记录，无 FATAL
6. 开机自启已按用户意愿设置（托盘菜单勾选，或 `powershell -File install-autostart.ps1`）

### 6. 安全规则

- 不要提交或暴露 `dsh-tray.json`（含本机路径）、`logs/`、任何 `*.log`（仓库 `.gitignore` 已排除，保持即可）
- `dsh-tray.ps1` 含中文，**必须 UTF-8 with BOM**；编辑后务必重新确认 BOM 存在
- 停止 dsh 时托盘会先校验进程身份（node/bun + 命令行含 dsh）再 `taskkill`，**不要绕过该校验去杀任意进程**
- 不要随意改端口，除非用户明确要求（两个 URL 都由 port 派生，改 `port` 即可，别手改 URL）
- 不要把托盘提升为管理员 / 服务运行 —— 它是普通用户级常驻程序
- 本机安全注意：若系统防火墙 Private 配置文件被关闭，其他 0.0.0.0 监听服务可能对局域网可见（与托盘无关，但值得提醒用户）

### 7. 运行约束

- 平台：Windows + PowerShell 5.1（`powershell.exe`），**不是 pwsh**
- 托盘常驻：**没有 Exit 菜单项**（设计决定）。彻底停止 = 菜单"停止 dsh" + `taskkill` 托盘进程
- 看门狗**只管生命周期、不管快慢**：进程活着绝不杀（慢启动不误杀）；进程消失才重启（5s→30s 退避）
- "开启新对话"优先用 UI Automation 驱动 GUI 自己的"新建会话"流程（点按钮→选新条目，创建/切换/持久化全由 GUI 处理）；GUI 不可达时回退 RPC 建会话 + 新标签页
- 健康检查与 dsh web 服务全部绑定 127.0.0.1，不对局域网开放
- 修改 `dsh-tray.ps1` 后需要重载托盘才生效：先杀旧托盘进程，再运行 `dsh-tray-launch.vbs`

### 8. 重要文件

```text
dsh-tray.ps1            # 主控：WinForms 托盘 + 看门狗 + 菜单 + 配置加载 + i18n
dsh-tray-launch.vbs     # 无窗口启动器（双击 / 开机自启入口）
install-autostart.ps1   # 开机自启安装 / 卸载
start-dsh.cmd           # 默认 dsh 启动模板（接收 %1 = 端口）
dsh-tray.example.json   # 配置模板（复制为 dsh-tray.json）
assets\dsh-whale.png    # 鲸鱼托盘图标
logs\dsh-tray.log       # 托盘自身日志（运行时生成，不入库）
```

---

## 功能一览（给人类）

| 功能 | 说明 |
|---|---|
| 🖱️ 托盘菜单 | 状态行 / 打开面板 / **开启新对话** / 重启 dsh / 停止 dsh / 复制最近日志 / 开机自启 |
| 🌐 中英双语 | 菜单、状态、通知气泡按系统语言自动切换（`language` 可强制） |
| 🐳 健康图标 | 健康 = 鲸鱼图标；异常 = 系统警告/错误图标 |
| 💬 通知气泡 | 状态跳变（启动/停止/恢复/异常/自动重启）时通知，不刷屏 |
| 🛡️ 看门狗 | 只管生命周期：进程活着绝不杀；崩溃才重启（5s→30s 退避） |
| 🎯 停止安全 | 杀进程前校验身份（node/bun + 命令行含 dsh），不误杀外来进程 |
| 🆕 开启新对话 | 驱动 GUI 自己的"新建会话"流程，**真正打开新空对话** |
| 📋 复制日志 | 一键复制最近 25 行 dsh 日志到剪贴板 |
| 🔄 防双开 | Mutex `Local\DshTray-<port>` |
| ⚙️ 配置文件 | 所有参数在 `dsh-tray.json`，无需改脚本 |

**使用**：双击 `dsh-tray-launch.vbs` 启动；开机自启在菜单里勾选"开机自启"；彻底停止 = 菜单"停止 dsh"后 `taskkill /PID <托盘PID> /F`。

## 📜 版本历史

| 版本 | 内容 |
|---|---|
| **v1.3.0** | 🔧 **默认端口修正为 3080**：此前默认 3090 实为作者本机 profile 覆盖（为与 WSL 实例共存），dsh 开箱默认是 3080（官方 README + 包内补丁确认）；本地配置显式写端口则不受影响 |
| **v1.2.0** | 🔥 **开启新对话真正生效**：UI Automation 驱动 GUI 自身流程，彻底绕开浏览器 localStorage 限制；GUI 不可用时回退 RPC + 新标签页 |
| **v1.1.1** | 修复新对话不可见：会话挂到当前工作区 + 唯一 fragment 强制新标签页 |
| **v1.1.0** | 正式发布版：配置文件、中英双语、新菜单、通知气泡、看门狗强化 |

## 📄 License

[MIT](./LICENSE)

---

## English

**dsh-tray** is a Windows-native tray switch + watchdog for the DeepSeek Harness (`dsh web`). Give the repo URL to your dsh-agent — you don't need to do anything but copy-paste.

- Menu: status / Open Dashboard / **New Conversation** / Restart / Stop / Copy Recent Log / Start with Windows (no Exit by design)
- New Conversation drives the GUI's own flow via UI Automation — a fresh empty conversation truly opens
- Watchdog manages lifecycle, not liveness: a live-but-slow process is never killed; crashes restart with 5s → 30s backoff; Stop verifies process identity before taskkill
- Config: copy `dsh-tray.example.json` → `dsh-tray.json`; default port **3080** (dsh's out-of-the-box default)
- Requires `npm i -g @deepseek-ai/dsh`; Windows PowerShell 5.1+; UTF-8 **with BOM** for `dsh-tray.ps1`
