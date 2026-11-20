# DingBootNotify

> 电脑一开机，钉钉群自动收到一条「我上线了」。

一个零依赖的 Windows 开机通知小工具：开机自动往钉钉群推送消息，断网时先记下开机时间，联网后自动补发；后台静默运行，不弹黑框。

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-lightgrey)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![License](https://img.shields.io/badge/license-MIT-green)

## 它解决什么问题

- 远程开机、跑渲染、跑训练、等编译，想知道「到底开了没」；
- 家里 / 实验室的机器开机后没人通知，出问题要过很久才发现；
- 现成的监控工具太重，只想在群里收一条简单消息。

整套东西只用到 Windows 自带的 PowerShell + 任务计划程序，不装任何第三方软件。

## 工作流程

```
Windows 开机
   │
   ▼
任务计划程序（SYSTEM 账户 / 最高权限，无需登录）
   │  wscript.exe（窗口模式 0，无黑框）
   ▼
RunNotify.vbs  ──启动──▶  DingBootNotify.ps1
                              │
                     ┌────────┴────────┐
                  有网络             没网络
                     │                 │
                立即推送钉钉      记录开机时间到 state/
                     │                 │
                     │            每 5 秒探测一次网络
                     │            联网后补发并删除记录
                     ▼                 ▼
                 【开机提醒】      【开机提醒·延迟推送】
```

## 特性

- **开机自动推送**：时间精确到秒，取系统真实开机时间（WMI `LastBootUpTime`）
- **断网补发**：开机网卡 / Wi-Fi 未就绪时先落盘，联网后补发，默认最多等 10 分钟（可配置）
- **静默运行**：VBS 以隐藏窗口拉起 PowerShell，全程无黑框
- **配置与代码分离**：Webhook、模板都在 `config.json`，代码里没有硬编码密钥
- **可选加签**：支持钉钉「加签」机器人（HMAC-SHA256）
- **一键安装 / 卸载**：`install.ps1` 自动复制文件、写配置、创建开机任务
- **可观测**：所有动作写入 `logs/boot-notify.log`
- **编码免疫**：主脚本纯 ASCII，中文全部放在 UTF-8 的 JSON 里，从根上避开 `errcode 310000` 乱码坑

## 目录结构

```
DingBootNotify/
├─ DingBootNotify.ps1    主脚本（纯 ASCII，任何编码保存都不会乱码）
├─ RunNotify.vbs         隐藏窗口启动器（ASCII / ANSI）
├─ config.example.json   配置模板（UTF-8）
├─ install.ps1           一键安装：复制文件 + 写配置 + 建开机任务
├─ install.cmd           双击入口（自动申请管理员权限）
├─ uninstall.ps1         卸载：删任务 / 可选删目录
├─ docs/
│  ├─ 从解压包部署.md    5 步装好（新手先看这个）
│  ├─ 手动部署.md        不用脚本、纯图形界面的完整步骤
│  └─ 常见问题.md        310000、收不到消息、任务历史等排查
├─ tests/
│  ├─ Simulate.ps1       模拟测试：本地假钉钉 + 临时沙箱
│  └─ MockDingTalk.py    假钉钉服务器（Python 标准库）
├─ logs/                 运行时自动生成（已 gitignore）
├─ state/                断网暂存的开机时间（已 gitignore）
└─ config.json           你的真实配置（已 gitignore）
```

## 快速开始

> 新手推荐：下载 ZIP → 解压 → 双击 `install.cmd`，3 分钟完成，见 [docs/从解压包部署.md](docs/从解压包部署.md)。

### 0. 前置条件

- Windows 10 / 11，管理员权限
- 一个钉钉群，且你是群主 / 管理员（能添加机器人）

### 1. 创建钉钉自定义机器人

1. 打开钉钉群 → 右上角「群设置」→「机器人」→「添加机器人」→「自定义」
2. 安全设置建议勾选 **加签**（比关键词 / IP 白名单更适合个人电脑）
3. 复制 **Webhook 地址**；如果开了加签，同时复制 **SEC 开头的密钥**

### 2. 获取代码

```powershell
git clone https://github.com/your-name/DingBootNotify.git
cd DingBootNotify
```

或者直接在 GitHub 页面下载 ZIP 解压。

### 3. 一键安装

双击 **`install.cmd`**（会自动申请管理员权限），按提示：

1. 粘贴 Webhook
2. 粘贴加签密钥（没有就回车）
3. 填设备名称（回车默认用电脑名）

安装脚本会自动完成三件事：

- 复制 `DingBootNotify.ps1`、`RunNotify.vbs` 到安装目录（默认 `D:\DingBootNotify`，没有 D 盘则用 `%LOCALAPPDATA%\DingBootNotify`）
- 生成 `config.json`
- 创建开机任务 `DingBootNotify`（SYSTEM 账户、最高权限、开机即运行、无需登录）

也可以手动用管理员 PowerShell：

```powershell
.\install.ps1
# 或完全非交互：
.\install.ps1 -Webhook "https://oapi.dingtalk.com/robot/send?access_token=xxx" -Secret "SECxxx" -DeviceName "工作站-01" -NonInteractive
```

### 4. 测试

```powershell
Start-ScheduledTask -TaskName DingBootNotify
```

钉钉群应立刻收到消息；`logs\boot-notify.log` 里也会有记录。

### 5. 整机验证

重启电脑，开机后 30–60 秒内应收到：

- 网络正常：`【开机提醒】xxx 已开机`
- 网络加载慢：`【开机提醒】xxx 延迟推送`（默认最长等待 10 分钟）

> 不想用一键脚本、想完全手动配置任务计划程序？见 [docs/手动部署.md](docs/手动部署.md)。

## 配置说明 `config.json`

| 字段 | 必填 | 说明 | 默认 |
| --- | --- | --- | --- |
| `webhook` | 是 | 钉钉机器人 Webhook 完整地址 | — |
| `secret` | 否 | 加签密钥（`SEC` 开头），开了加签才需要 | 空 |
| `deviceName` | 否 | 消息里的设备名 | `%COMPUTERNAME%` |
| `onlineTemplate` | 否 | 正常联网时的消息模板 | 见示例 |
| `delayedTemplate` | 否 | 断网补发时的消息模板 | 见示例 |
| `retryMaxSeconds` | 否 | 断网最长等待秒数 | `600` |
| `retryStepSeconds` | 否 | 每次探测网络间隔秒数 | `5` |
| `networkProbeUrls` | 否 | 联网探测地址（数组），默认百度 + 钉钉，内网可改 | 见说明 |

模板占位符：`{device}` 设备名、`{bootTime}` 开机时间、`{sendTime}` 发送时间，`\n` 表示换行。

示例：

```json
{
  "webhook": "https://oapi.dingtalk.com/robot/send?access_token=你的token",
  "secret": "",
  "deviceName": "工作站-01",
  "onlineTemplate": "【开机提醒】{device} 已开机\n开机时间：{bootTime}",
  "delayedTemplate": "【开机提醒】{device} 延迟推送\n开机时间：{bootTime}",
  "retryMaxSeconds": 600,
  "retryStepSeconds": 5
}
```

修改配置后不需要重装，下次开机自动生效；也可以直接 `Start-ScheduledTask -TaskName DingBootNotify` 验证。

## 为什么主脚本是纯 ASCII

Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时，会按系统 ANSI 编码（中文系统即 GBK）解析，中文变乱码，钉钉返回 `errcode 310000`。

本项目把**所有中文都放进 `config.json`**（显式按 UTF-8 读取），`DingBootNotify.ps1` 只保留英文和代码，因此无论用什么编辑器、保存成什么编码都不会踩坑。这是本项目和大多数网上脚本最大的区别。

## 常见问题（简版）

| 现象 | 优先排查 |
| --- | --- |
| 钉钉返回 `errcode 310000` | 中文乱码：确认 `config.json` 以 UTF-8 保存；不要改回旧式内嵌中文脚本 |
| 双击测试没消息 | Webhook 是否完整；`logs\boot-notify.log` 是否有 `Send error` |
| 重启后收不到 | 任务计划程序 → 任务「历史记录」看是否被触发；确认任务存在且启用 |
| 笔记本电池下不运行 | 安装脚本已默认允许电池运行；手动装需取消「只有交流电源才启动」 |
| 任务显示运行成功但群没消息 | 看日志里的 `errcode`；加签密钥是否正确 |

完整排查流程见 [docs/常见问题.md](docs/常见问题.md)。

## 卸载

```powershell
.\uninstall.ps1                 # 只删开机任务
.\uninstall.ps1 -RemoveFiles    # 同时删除安装目录
```

或在「任务计划程序」中删除任务 `DingBootNotify`，再删除安装目录。

## 模拟测试

不想动真实开机任务、也不想往真实群里发消息，可以先跑一遍隔离测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Simulate.ps1
```

临时沙箱 + 本地假钉钉服务器，覆盖 6 个场景：联网推送、断网落盘、联网补发、VBS 静默启动、加签签名、任务计划 BootTrigger。测完自动清理，不读取也不覆盖你的 `config.json`。

详见 [tests/README.md](tests/README.md)。

## 安全说明

- 仓库里的 `config.json` 已被 `.gitignore` 排除，**不要**把真实 Webhook / 密钥提交到公开仓库
- 建议机器人开启「加签」，Webhook 泄露也无法直接调用
- 任务以 SYSTEM 运行，只执行本目录内的 VBS / PS1，不下载、不联网拉取任何外部代码

## Roadmap

- [ ] 飞书 / 企业微信 / Telegram 等多通道
- [ ] Markdown 消息模板
- [ ] 开机后延迟 N 秒再发（等 VPN 起来）
- [ ] 图形化配置小工具（托盘）

## License

[MIT](LICENSE)
