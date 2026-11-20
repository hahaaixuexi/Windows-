# 模拟测试

不想动真实开机任务，又想把流程跑一遍？这个测试会在**临时沙箱**里复制一份脚本，配一个**本地假钉钉服务器**，把关键路径全部走完。

- 不读取、不覆盖你真实的 `config.json`
- 不向真实钉钉群发送任何消息
- 测试任务名为 `DingBootNotify_SimTest`，结束自动删除
- 沙箱目录结束后自动清理

## 运行

需要 Windows + Python 3（只用标准库），在仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Simulate.ps1
```

参数：

| 参数 | 说明 |
| --- | --- |
| `-Port 18080` | 假钉钉服务器端口，被占用就换一个 |
| `-SkipTaskTest` | 跳过任务计划程序端到端测试（不想创建任何任务时用） |
| `-KeepSandbox` | 保留临时目录，便于查看日志与接收记录 |

## 覆盖的场景

| # | 场景 | 验证点 |
| --- | --- | --- |
| 1 | 联网开机 | 立即 POST、消息为 `text`、中文与 3 行模板完整、时间格式正确 |
| 2 | 断网开机 | 不发消息、写入 `state/pending-boot.txt`、日志记录等待 |
| 3 | 联网后恢复 | 补发「延迟推送」、开机时间与记录一致、状态文件被删除 |
| 4 | VBS 启动 | `wscript.exe` 拉起后 30 秒内收到消息，验证 Windows PowerShell 5.1 兼容 |
| 5 | 加签 | URL 带 `timestamp` + `sign`，按 HMAC-SHA256 重算签名一致 |
| 6 | 任务计划 | 测试任务包含 `<BootTrigger>`，触发后能收到消息 |

## 说明

- 场景 4、6 由 `powershell.exe`（Windows PowerShell 5.1）执行，最贴近开机时的真实环境
- 真正的「重启电脑触发」无法模拟，任务测试用 `Start-ScheduledTask` 走同一套执行路径；最终仍建议真机重启验证一次
- 沙箱里的 `config.json` 指向 `http://127.0.0.1:<port>`，不会出网
