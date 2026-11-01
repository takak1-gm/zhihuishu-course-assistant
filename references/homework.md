# 客观题操作

## 加载工具库

```powershell
$skillPath = 'C:\path\to\zhihuishu-course-assistant'
$coursePort = 9223
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $skillPath 'scripts\course-ui.ps1')))) -SkillRoot $skillPath -Port $coursePort
```

`$listPageId`、`$exercisePageId` 来自当次 `/json/list`。新开页面后重新枚举，不拼接从未观察过的作业 URL。

历史 Vue/Element UI 的 DOM 如下，不保证后续版本一致。先观察再使用：

| 用途 | 选择器 |
|---|---|
| 作业卡片 | `.title-wrapper`，其中 `.tit` 是名称，`.btn.do` 是开始按钮 |
| 答题卡 | `li[questionid]` 按页面顺序；第一题有时没有 indexno |
| 单选/多选 | `label.el-radio` / `label.el-checkbox`，内含 input |
| 发起提交 | `.Submithomeworkbtn` |
| 确认框 | 可见 `.el-dialog__wrapper` 和其中“提交”按钮 |

## 读取、推理、填写

```powershell
Invoke-CoursePage $listPageId 'document.body.innerText'
Open-CourseAssignment $listPageId '从当前清单读取的作业名称'
# 重新枚举，得到实际 $exercisePageId。
$questions = Get-CourseQuestions $exercisePageId
$questions | ConvertTo-Json -Depth 8
```

先统计题型；没有 radio/checkbox 的题不能当成空客观题。只读模式不选择答案。题号按独立行确认，避免第 1 题与第 11 题混淆。切题使用实际鼠标事件，在控制端轮询 DOM，不依赖后台网页可能被节流的 JS 定时器。

AI 理解题意并核对资料后构造答案。以下仅是**格式示例，不是真实课程答案**：

```powershell
$reviewedAnswers = @('B', 'AC', 'D')
Set-CourseAnswers $exercisePageId $reviewedAnswers
```

批量填写仅用于全部审定且题数一致的纯客观题作业；校验选项范围、单选数量、实际选中集合，纠正多选的多余选项，再切回第一题触发保存。不把一章答案套另一章，不覆盖未授权修改的草稿。

混合主客观题需逐题处理客观题，保留主观题原状，不直接调用要求全题数匹配的批量函数。判断题若也是 radio，按当前“正确/错误”可见选项处理；填空、拖拽等未实现题型另行观察 UI。

提交前回访答题卡，检查选项保留、题号正确、无保存错误。长选项超出视口时先正常滚动，再获取新矩形；不使用过期或屏幕外坐标。

## 提交与验收

只要求草稿时停在草稿，提供题号、答案、必要依据。用户明确说“自行提交”“完成后提交”等时：

```powershell
Submit-CourseHomework $exercisePageId -Authorized
```

确认框不是“是否确认提交作业”时函数停止。例如“还未做完题目”提示，需要先关闭，检查漏选或保存失败。混合作业仅填客观题时，按用户范围核对留空主观题，再通过 UI 处理部分提交；本函数不自动确认未答题警告。

函数等待详情页出现已批阅/待批阅。但本地超时不一定代表服务器失败：

1. 刷新原课程“作业考试 → 全部”。
2. 对应作业明确显示已批阅、待批阅、已提交或查看作业后，记为已提交。
3. 未核实前不重复提交，不申请重做；申请重做不是通信重试。

仅对确认无业务成功的临时失败重试。连续 3 次无变化后记录阻碍，让用户查看。用户手动提交过的先核对状态，不再覆盖或重复提交。

## 已验证的故障经验

- `.click()` 在部分页面无效。用 CDP mouseMoved / mousePressed / mouseReleased，坐标来自当前 `getBoundingClientRect()`。
- 滚动、弹窗动画、调整窗口大小后等待布局稳定并重新获取矩形。工具库有短暂等待，特殊布局仍需重新观察。
- hidden 页面实际输入可能无效，请用户将浏览器置前。`Page.bringToFront` 不保证恢复遮挡、锁屏或虚拟桌面状态。不要伪造 visibility/focus 或禁用检测。
- 后台页 JS 定时器有时不执行，优先在控制端短间隔、有限次数地只读轮询。
- 同作业多个标签页容易错配。记录精确 targetId，只清理自己误开的重复页。
- 空白详情页不等于零题，先检查正常入口和登录态；权限拒绝时不绕过限制。
- “已批阅，成绩未发布”只能确认状态，不能据此算正确率或断言全对。
