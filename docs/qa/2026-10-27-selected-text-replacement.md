# Selected Text Replacement Verification

本记录对应 2026-10-27 的稳定按钮版本，替换入口规则以 `../plans/2026-10-27-selected-text-replacement-plan.md` 顶部的交互修订为准。

## 环境与自动验证

- macOS 27.0.1，arm64；辅助功能和发送事件权限检查均为 true。
- 授权态实测使用独立 DerivedData 目录中的最新 Direct Debug 应用，未使用原先运行的旧构建。
- 相关 XCTest 实际执行 47 项，0 失败：`SelectedTextReplacementTests` 18 项，`SelectedTextProbePolicyTests` 7 项，`SelectedTextProbeExecutorTests` 4 项，`SinglePressLookupCoordinatorTests` 9 项，`SinglePressLookupRequestTests` 9 项。
- Direct Debug、Direct Release、App Store Release 均构建成功。App Store 使用 `SnapTra Translator` scheme，Direct 使用 `SnapTra Translator Direct`；两个 Release 使用不同的 DerivedData 目录。
- `SelectedTextService.swift`、`SelectedTextProbeExecutor.swift`、`SelectedTextReplacement.swift` 的局部 Swift 类型检查、字符串目录 JSON 校验及 `git diff --check` 通过。

日志位于本机任务临时目录 `/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/`：

- `replacement-stable-button-tests.log`
- `replacement-stable-button-direct-debug.log`
- `replacement-stable-button-direct-release.log`
- `replacement-stable-button-appstore-release.log`

## 最新 Direct 构建的实际界面行为

以下原生场景使用独立的可丢弃 AppKit / NSTextView 测试窗口，经过现有快捷键、真实翻译、浮窗按钮及实际粘贴事件链路；没有向聊天应用发送内容。

| 场景 | 观察结果 | 结论 |
| --- | --- | --- |
| 可写原生选区，译文完成后鼠标移到屏幕角落 | “替换原文”仍显示且可点击；点击后 `SnapTra native replacement test.` 变为 `SnapTra原生替换测试。`，浮窗关闭 | 通过 |
| 同样的原生文本设为只读 | 按钮仍显示；点击提示 `The original selection is not editable.`，文本保持不变，按钮保留 | 通过 |
| 翻译完成后将原选区折叠为插入点 | 按钮仍显示；点击提示原文或选区变化，文本保持不变 | 通过 |
| 上一场景失效后再次点击 | 提示无法确认原始选区、需重新选择并翻译；没有在当前插入点粘贴 | 通过 |
| 可写控件接收粘贴事件但故意忽略粘贴 | 提示 `Replacement was sent. Check the original app.`；按钮保留且 AXEnabled 为 false | 通过 |
| 上一场景再次执行按钮 action | 没有第二次粘贴；测试窗口日志只有一条 `fixturePasteReceived=true ignored=true` | 通过 |

无上下文提示的界面验证来自原上下文失效后的路径；未单独构造 AX 复制回退产生 `contextID == nil` 的完整界面场景。服务入口对 nil 上下文在激活目标、写剪贴板或发送事件前返回失败。

## 浏览器与应用兼容性边界

- Ego Lite 0.6.1.13 的自建 textarea 测试页：已确认 DOM 焦点为测试 textarea，且系统 AX 一度能读取该控件的角色、原选区、原文、窗口和可写属性。译文完成后鼠标移远，按钮仍显示。
- 点击替换后，服务返回“已发送，请检查原应用”，但 DOM 中的原文没有变化，不能记为写回成功。
- 后续诊断中，页面内 `document.hasFocus()` 为 true，而应用级 `AXFocusedUIElement` 返回 noValue；同页通过浏览器工具执行的原生 paste control 能改变测试文字，独立 CGEvent 诊断未在测试页观察到键盘事件。系统前台应用在诊断期间也发生过变化。这些证据不足以确定是浏览器适配还是测试焦点环境导致，网页完整写回仍待验证。
- 微信缺少可验证的原始 AX 焦点编辑控件时仍无法安全写回；稳定显示按钮不等于已支持该控件。没有放宽为对当前插入点直接粘贴。
- 未将以上自建原生窗口的结果扩展为 TextEdit、Notes、Safari、Chrome、VS Code、微信或其他应用的兼容性结论。
- 未实际执行外屏插拔、旋转、缩放及主屏切换；坐标变换与过期配置拒绝由合成屏幕配置测试覆盖。

## 本轮交付范围

按钮显示已与鼠标位置、选区几何、提前可写性和是否取得原始替换上下文分离；完整的 Direct 选中文本译文显示按钮，点击后检查原始目标及可写性。流式 partial、手动输入、OCR 和 App Store 结果不提供该入口。

本轮未提交、未推送、未发布。尚未达到原计划中“至少一个浏览器标准输入框完成替换及撤销”的完整兼容性验收标准。
