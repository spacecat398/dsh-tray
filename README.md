# dsh-tray

Windows 原生 **DeepSeek Harness（dsh web）托盘开关 + 看门狗**。

系统托盘里的 dsh 开关：启动 / 重启 / 停止 dsh web，健康监控，崩溃自动拉起，还带"开启新对话"和日志复制。菜单语言跟随系统（中文 / English），所有参数通过 `dsh-tray.json` 配置。

```
dsh-tray.lnk (开机自启)
  └─ wscript → dsh-tray-launch.vbs
       └─ PowerShell -WindowStyle Hidden → dsh-tray.ps1
            ├─ 启动: cmd /c start-dsh.cmd <port>  →  dsh web --port 3090
            ├─ 停止: 按端口找 PID → 身份校验 → taskkill /T /F
            ├─ 健康: GET http://127.0.0.1:3090/ 每 10 秒
            └─ 看门狗: 崩溃自动拉起（5s→30s 退避），慢启动不误杀
```

## ✨ 功能

| 功能 | 说明 |
|---|---|
| 🖱️ 托盘菜单 | 状态行 / 打开面板 / **开启新对话** / 重启 / 停止 / 复制最近日志 / 开机自启 |
| 🌐 中英双语 | 菜单、状态、通知气泡按系统 UI 语言自动切换（`language` 可强制） |
| 🐳 健康图标 | 健康 = DeepSeek 鲸鱼图标；异常 = 系统警告/错误图标 |
| 💬 通知气泡 | 状态跳变（启动/停止/恢复/异常/自动重启）时通知，不刷屏 |
| 🛡️ 看门狗 | **只管生命周期、不管快慢**：进程活着绝不杀；进程消失才重启，带退避 |
| 🎯 停止安全 | 杀进程前校验身份（node/bun + 命令行含 dsh），不误杀占用端口的外来进程 |
| 🆕 开启新对话 | **真正打开一个新的空对话**：通过 UI Automation 驱动 GUI 自己的"新建会话"流程（点按钮→选新条目），创建/切换/持久化全由 GUI 处理；GUI 不可用时回退为 RPC 建会话 + 新标签页 |
| 📋 复制日志 | 一键把最近 25 行 dsh 日志复制到剪贴板 |
| 🔄 防双开 | Mutex `Local\DshTray-<port>` |
| ⚙️ 配置文件 | 所有参数在 `dsh-tray.json`，无需改脚本 |

> **设计决定：没有 Exit 菜单项。** 托盘常驻、看门狗全自动；彻底停止 = 菜单"停止 dsh"后 `taskkill /PID <托盘PID> /F`。

## 📦 安装

1. 把本仓库克隆/解压到任意目录，例如 `C:\dsh-tray\`
2. 复制 `dsh-tray.example.json` 为 `dsh-tray.json`，按需修改（至少确认 `startscript` 指向你的 dsh 启动脚本）
3. 双击 `dsh-tray-launch.vbs` 启动托盘
4. （可选）开机自启：托盘菜单勾选 **开机自启**，或运行：
   ```powershell
   powershell -ExecutionPolicy Bypass -File install-autostart.ps1
   ```

前置要求：Node.js 全局安装 dsh（`npm i -g @deepseek-ai/dsh`），`dsh web` 可启动。

## ⚙️ 配置（dsh-tray.json）

| 键 | 默认 | 说明 |
|---|---|---|
| `port` | `3090` | dsh web 端口 |
| `startscript` | `start-dsh.cmd` | 启动脚本（托盘以 `<port>` 作为 %1 调用） |
| `dshlogfile` | `logs\dsh-web.log` | "复制最近日志"读取的文件 |
| `healthintervalseconds` | `10` | 健康检查间隔 |
| `startupgraceseconds` | `120` | 启动宽限期（期间只显示 Warming up） |
| `restartdelayseconds` | `5` | 崩溃重启基础延迟（退避上限 ×6 = 30s） |
| `language` | `auto` | `auto` / `zh` / `en` |
| `notifications` | `true` | 状态跳变通知气泡开关 |
| `whaleicon` | `true` | 健康时使用鲸鱼图标（`assets\dsh-whale.png`） |

## 🛡️ 安全说明

- dsh web / 健康检查全部绑定 **127.0.0.1**，不对局域网开放；
- 停止操作先做进程身份校验，不会误杀占用端口的外来进程；
- 注意：若系统防火墙 Private 配置文件被关闭，本机其他 0.0.0.0 监听服务（如 Orca Web）可能对局域网可见 —— 与本托盘无关，但值得检查。

## 🧪 已验证（Windows 11 / PS 5.1）

- 看门狗：强杀 dsh 后 ~25s 内自动拉起；慢启动（>120s 宽限）不会被误杀
- 身份校验：外来进程占 3090 时停止操作只告警不动手
- 菜单/日志复制/语言切换/自启开关 均实测通过

## 🛠 开发

```
dsh-tray.ps1            # 主控（PS 5.1 + WinForms）
dsh-tray-launch.vbs     # 无窗口启动器
install-autostart.ps1   # 自启安装/卸载（菜单里也能开关）
start-dsh.cmd           # 默认 dsh 启动模板
dsh-tray.example.json   # 配置模板
assets\dsh-whale.png    # 鲸鱼托盘图标
```

> ⚠️ `dsh-tray.ps1` 含中文字符串，必须保存为 **UTF-8 with BOM**（PS 5.1 无 BOM 会按 ANSI 解码导致语法错误）。

## 📄 License

[MIT](./LICENSE)

---

## English

**dsh-tray** is a Windows-native tray controller + watchdog for the DeepSeek Harness (`dsh web`).

- Menu: status / Open Dashboard / **New Conversation** / Restart / Stop / Copy Recent Log / Start with Windows
- UI language follows the OS (zh / en), overridable via `language` in `dsh-tray.json`
- Watchdog manages *lifecycle, not liveness*: a live-but-slow process is never killed; only a crash schedules a restart (5s → 30s backoff)
- Stop verifies process identity before `taskkill` (node/bun + command line referencing dsh)
- New Conversation drives the GUI's own "new conversation" flow via UI Automation (click the sidebar button, select the new entry) — the GUI handles creation, selection and its localStorage state, so a fresh empty conversation truly opens. Falls back to the RPC + new-tab flow when the GUI is not reachable.
- Config: copy `dsh-tray.example.json` → `dsh-tray.json` and edit paths

Requires `dsh` installed globally (`npm i -g @deepseek-ai/dsh`). Run on Windows PowerShell 5.1+.
