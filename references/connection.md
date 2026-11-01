# 连接、发现与视频

## 浏览器连接

先检查现有实例。示例端口 `9223` 不是固定配置，使用实际可用端口：

```powershell
Invoke-RestMethod 'http://127.0.0.1:9223/json/version'
(Invoke-WebRequest 'http://127.0.0.1:9223/json/list' -UseBasicParsing).Content
```

如需新 Edge，验证程序路径。Windows 常见路径为 `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`，也可查询 `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe`。用户手动启动时可提供整行命令，替换端口和配置目录：

```text
msedge.exe --remote-debugging-address=127.0.0.1 --remote-debugging-port=9223 --user-data-dir=C:\CourseBrowserProfile --no-first-run --new-window https://hike-teaching-center.polymas.com
```

独立目录不共享日常浏览器登录态，用户在窗口中登录。调试端口只对本机开放，不复制旧配置给其他 AI。启动或操作被执行环境拒绝时说明阻碍，交由用户处理，不用其他启动器或底层控制规避安全检查。历史上曾出现命令被拦或浏览器崩溃，不是所有机器的固定行为。

## 加载客户端

直接执行 ps1 被执行策略限制时，可在当前环境允许的前提下从文件加载脚本块；不修改执行策略。脚本块也被禁止时停止并报告。

```powershell
$skillPath = 'C:\path\to\zhihuishu-course-assistant'
$coursePort = 9223
$client = [scriptblock]::Create([IO.File]::ReadAllText((Join-Path $skillPath 'scripts\cdp.ps1')))
# $pageId 取自 /json/list 的实际结果。
& $client -Port $coursePort -TargetId $pageId -Expression 'document.title'
& $client -Port $coursePort -TargetId $pageId -Expression 'document.body.innerText'
```

客户端仅连接 `127.0.0.1`；目标不唯一时拒绝执行。重载通常保留 targetId，关闭重开会改变 ID。Promise 表达式需要 `-AwaitPromise`；CDP 方法用 `-CdpMethod` 和 JSON `-CdpParams`。文件按 UTF-8 读写，用户数据放任务输出目录，不写入技能目录。

## 路由与发现

下表是历史观察，先在当前环境验证：

| 页面 | 已观察到的形式 |
|---|---|
| 课程中心 | `hike-teaching-center.polymas.com/.../ai-course-center` |
| 翻转课资源 | `wenda.zhihuishu.com/stu/courseInfo/studyResource?courseId=...` |
| 作业清单 | `wenda.zhihuishu.com/stu/courseInfo/homeworkExam?courseId=...` |
| 视频 | `hike.zhihuishu.com/aidedteaching/sourceLearning/sourceLearning?courseId=...&fileId=...` |
| 作业答题 | `hiexam.zhihuishu.com/.../exerciseList/...` |
| 提交后详情 | `hiexam.zhihuishu.com/.../doHomeWorknew/...` |

AI 智课 ID 可能是字符串，翻转课常见数字。卡片图片名和十六进制字符串不一定是 courseId。

优先读 DOM。经授权需要带登录态的只读接口时，在对应页面内 `fetch(...,{credentials:'include'})`，无需提取 cookie。访问被拒时不修改身份/权限参数。不调用隐藏答案或评分接口。页面个人信息不传入公开搜索引擎。

请求发现用 `performance.getEntriesByType('resource')`，只能得到 URL 和时序，不能证明业务成功，也不能直接读取响应正文。历史接口可能变更，不照抄为永久契约。

## 顺序播放

先通过 UI 打开所需视频，再用实际课程 ID 和精确标签页 ID：

```powershell
$player = [scriptblock]::Create([IO.File]::ReadAllText((Join-Path $skillPath 'scripts\autoplay.ps1')))
New-Item -ItemType Directory -Path 'C:\task-output' -Force | Out-Null
& $player -SkillRoot $skillPath -Port $coursePort -CourseId $courseId -TargetId $videoPageId -LogPath 'C:\task-output\autoplay.log'
```

脚本针对翻转课普通 HTML5 播放器，按当前目录顺序跳过非视频条目。不会自动选择课程、打开首个待学视频或登录。

每 5 秒读真实状态，自然结束后点击下一项；每页只初次启动一次，手动暂停后不强制恢复。每分钟写心跳，状态变化立即记录。连续通信失败最多重试 6 次。关闭目标页、课程变化、播放器错误、自动播放被阻止或播完全部视频时停止。`-MaxHours` 默认 12 小时。

需要后台运行时使用环境支持的方式；Windows `Start-Process` 隐藏辅助窗口，保留 PID、日志和错误输出路径。避免重复启动。可关闭目标视频页停止，或结束已确认属于本任务的辅助进程。

验收：日志 playing；两次读取 `video.currentTime` 确实增长；自然结束后出现 next 并在新视频继续增长。不要快进真实课程来测试切换，可先离线模拟。
