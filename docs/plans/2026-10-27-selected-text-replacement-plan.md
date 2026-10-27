# Selected Text Replacement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 SnapTra GitHub／Direct 版增加“替换原文”按钮，让用户选择某个已完成的译文，写回最初选中的可编辑文本，并在目标变化时停止操作。

**Architecture:** 复用 `SelectedTextService` 的 AX 串行执行域和现有翻译链路，建立独立于翻译 `lookupID` 的替换会话。由 MainActor 上的小型替换服务协调焦点、剪贴板和一次模拟粘贴；来源身份、选区和原始文本在提交前重新验证。复制回退与粘贴共享一把剪贴板操作锁，SwiftUI 仅消费值类型状态与会话 ID。

**Tech Stack:** Swift 6、SwiftUI、AppKit、ApplicationServices / AXUIElement、CoreGraphics / CGEvent、Swift Concurrency、XCTest；macOS 14+，系统翻译沿用现有 macOS 15+ 限制；不增加依赖。

**交互修订（优先于下文旧的入口资格规则）：** Direct 版已完成的选中文本译文稳定显示“替换原文”，显示条件只依赖渠道、结果来源及译文完成状态；OCR、手动输入和 App Store 版没有入口。鼠标位置、选区几何、辅助功能权限和提前判断的可写性不再控制按钮显示。翻译时只保存可确认的来源控件、选区和原文身份，点击时再检查权限、目标身份及可写性。没有可靠原始目标、只读或选区变化时给出明确失败提示；不会把译文粘贴到后来选中的其他目标。已经发送而未确认的提交保留禁用按钮，禁止重复发送。

**最新验证：** 稳定按钮版本的 47 项相关 XCTest、Direct Debug 和双渠道 Release 构建通过；原生独立测试窗口通过鼠标移远后替换、只读拒绝、选区变化拒绝、失效后反馈、未确认发送后禁用及单次粘贴验证。自建浏览器测试页的按钮稳定性通过，完整写回未通过；详细证据及未验证范围见 `../qa/2026-10-27-selected-text-replacement.md`。

---

## 1. 编写基线与执行约束

- 编写日期：2026-10-27。
- 当前 HEAD：`2c1b111`，`chore(appcast): add 1.3.11-beta.3 release entry [skip ci]`。
- 本文以当前工作树为依据。工作树已有未提交的“鼠标命中选区”相关修改，涉及 `AppModel.swift`、`SelectedTextService.swift`、`SelectedTextProbeExecutor.swift`、路由、测试和文案；实现必须基于这些改动逐个符号接入。
- 本次计划编写只新增本文档，没有实现功能，也没有执行构建、单元测试或跨应用输入测试。
- 项目实际已有 `SnapTra TranslatorTests` target；仓库 `AGENTS.md` 中“单一 target、没有测试 target”的描述已落后于工程。复用现有测试 target。
- `SnapTra Translator` scheme 包含 XCTest；`SnapTra Translator Direct` scheme 的 Testables 目前为空。共享策略和替换服务使用前者测试，Direct 版用于渠道构建和授权态实测。
- 应用源文件目录使用 `PBXFileSystemSynchronizedRootGroup`，新增 Swift 源文件通常自动进入两个 app target；新增测试文件需要在 `project.pbxproj` 的测试 group、file reference、build file 和 Sources phase 注册。
- `docs/plans/2026-10-26-pointer-scoped-selection-translation-plan.md` 提到同期替换字段和旧的替换计划路径，但当前源码没有对应实现。不得据此假定 `replacementSessionID` 等能力已经存在；本文使用实际存在的 `SelectionContext` 接入。
- 不重置、覆盖或暂存无关修改。阶段检查点用于审查；commit、push、发布和对外消息需要另外的用户指令。
- 本文开头的技能指向是计划模板约定。后续执行环境若没有该技能，按本文任务顺序执行即可，不安装技能、不因此阻塞实施。

## 2. 首期产品范围

### 2.1 用户操作

1. 用户在来源应用的可编辑输入框中选中文字。
2. 鼠标位于该选区内，通过现有快捷键触发选中文本翻译。
3. SnapTra 在原有译文旁显示“替换原文”；有多个翻译服务时，每个已完成的译文都有自己的按钮。
4. 用户点击某一译文的按钮，SnapTra 核对最初的输入框和选区，返回来源输入框并粘贴该译文。
5. 验证替换完成后关闭浮窗，后续撤销由来源编辑器的 ⌘Z 完成。

### 2.2 行为表

| 场景 | 首期行为 |
| --- | --- |
| Direct 版，前台可编辑控件，已获取可靠范围和原始选中文字 | 创建替换会话；译文完成后提供替换按钮 |
| 同一次翻译有多个结果 | 用户点击哪个结果，就替换为哪个结果，不选取“最快返回”的结果 |
| 翻译加载中、失败、重译中仍显示旧结果 | 相应结果不可替换；保留现有显示行为 |
| 切换目标语言 | 保留原替换目标，等待新请求的对应结果完成后再允许替换 |
| 用户开始编辑 SnapTra 内的原文 | 当前替换会话失效；重新提交只生成普通译文，需回来源应用重新选中才能再次替换 |
| 只查看或选择浮窗中的译文 | 允许浮窗临时取得键盘焦点；替换前恢复并验证来源焦点 |
| 来源控件只读、不可确定可编辑性、只有 marker 而没有可靠字符范围 | 翻译和复制继续可用，不提供替换 |
| 鼠标命中非前台窗口中的选区 | 沿用现有翻译能力；首期不创建替换会话 |
| OCR 单词、OCR 段落、框选图片、手动输入、原位覆盖显示 | 沿用现有功能，不创建写回目标 |
| App Store 版 | 不展示替换入口，不执行替换所需的 AX、激活或键盘注入 |
| 选区范围、原文、来源窗口或控件已改变 | 终止替换，显示“原文或选区已变化，请重新选择”；不能退化为在光标处插入 |
| 用户切换到其他应用或同一应用的另一窗口 | 使会话失效；替换服务不按旧 PID 把用户强行切回 |
| 快速连续点击或同时点击两个服务结果 | 同一会话最多发送一次粘贴 |
| 粘贴已发送但无法验证结果 | 禁止自动重试；提示检查原应用，保留复制能力 |

首期不增加设置项，复用现有“选中文本翻译”开关、权限和浮窗保留机制。短按保留、按住查看、关闭持续翻译和固定面板均需验证按钮可达性；只有替换会话有效时，鼠标进入面板的动作可以受保护，不能借此扩大普通 OCR 浮窗的保留范围。

### 2.3 本次不包含

- 全局 Enter 替换、翻译完成后自动替换、替换后自动发送消息。
- 修改只读网页、PDF、截图或终端滚动输出。
- 用 `AXValue` 读取／重写整个文档，或按相同字符串搜索另一个位置来替换。
- 自动恢复用户已经改变的字符选区。
- App Store 版的新系统服务、浏览器扩展或外部辅助进程。
- 新翻译服务、富文本格式重建或通用自动化框架。

## 3. 当前接入点

行号用于定位编写时的源码，实施时以符号为准。

| 文件 / 符号 | 当前行为 | 计划调整 |
| --- | --- | --- |
| `SnapTra Translator/SelectedTextService.swift`，`SelectedTextSnapshot`，约 11 行 | 对外只有文本、范围、bounds、来源、hitTest | 增加默认 nil 的替换会话元数据，或在最终路由采用时单独返回会话值 |
| 同文件，`SelectionContext`，约 55 行 | 保存 AX 控件、window、PID、range、规范化文本 | 保存原始文本；在采用候选后创建独立 replacement context |
| 同文件，`probeCandidate`，约 339 行 | `commitSelectionContext` 保存命中候选 | 继续只保存最终命中的候选；替换能力不能决定是否允许翻译 |
| 同文件，`clipboardSelectionSnapshot`，约 950 行 | 模拟复制并备份／恢复剪贴板 | 接入共享剪贴板锁；保留原始复制文本用于精确比对 |
| `SnapTra Translator/SelectedTextProbeExecutor.swift`，`SelectedTextProbePolicy.snapshot` | 先 trim，再把文本传给上下文提交闭包 | 同时保留原始字符串和翻译用字符串，不能用 trim 后文本证明选区未变 |
| `SnapTra Translator/AppModel.swift`，`performLookup`，约 1268 行 | 最终选择 selected-text 或 OCR | 仅在 selected-text 路由被最终采用、展示浮窗之前准备替换会话 |
| 同文件，`stopMouseTracking`，约 957 行 | 同时释放跟踪用 selection context | 跟踪上下文按原规则清理；独立的替换上下文不在此误删 |
| 同文件，`translateCurrentParagraphOriginal`，约 2402 行 | 切换语言／重译会生成新 lookupID | 会话 ID 保持稳定；结果仍绑定最新 lookupID |
| 同文件，`ServiceTranslationResult`、`performThirdPartySentenceTranslations`，约 217、2481 行 | LLM partial 和最终结果都标记 `.ready`；partial 的 duration 为 nil | 增加明确完成标记，替换不能由 `.ready` 单独授权，也不把耗时字段当作完成状态 |
| 同文件，`updateParagraphOriginalText`，约 2371 行 | 修改面板原文 | 开始编辑时使替换会话失效，避免把手工文本写回旧选区 |
| 同文件，`cancelActiveLookupWork`、`hideOverlay`、休眠与应用切换 | 取消请求和隐藏结果 | 清理替换会话与提交任务；区分暂时隐藏窗口和结束会话 |
| `SnapTra Translator/OverlayWindowController.swift`，`setInteractive`，约 1228 行 | 接受鼠标时立即 `makeKey()` | 分开“接受鼠标”和“请求键盘焦点”，仅 selected-text 替换场景改变默认焦点策略 |
| `SnapTra Translator/OverlayView.swift`，`paragraphResultView`、`paragraphServiceResultHeader` | 系统译文和第三方译文各有复制按钮 | 接入统一替换按钮和局部错误反馈，不改全局 CopyButton 语义 |
| 同文件，`EditableParagraphTextView`、`focusIfNeeded` | 原文编辑器创建时自动请求焦点 | selected-text 初次展示不自动聚焦；用户明确进入编辑时再请求 |
| `SnapTra Translator/UpdateChecker.swift`，`DistributionChannel` | GitHub 支持选中文本，App Store 不支持 | 复用现有 capability；服务入口和 UI 均检查，测试使用显式渠道输入 |

## 4. 数据、所有权与线程边界

### 4.1 会话与翻译请求分开

创建 `SnapTra Translator/SelectedTextReplacement.swift`，放置纯值类型和可测试的决策逻辑。核心对外模型建议为：

```swift
import Foundation

nonisolated struct SelectedTextReplacementSession: Equatable, Sendable {
    let id: UUID
    let sourceAppIdentifier: String?
    let sourceApplicationName: String
    let sourceAppProcessIdentifier: pid_t
}

nonisolated enum SelectedTextReplacementOutcome: Equatable, Sendable {
    case verified
    case pasteDispatched
}

nonisolated enum SelectedTextReplacementFailure: Error, Equatable, Sendable {
    case unsupportedChannel
    case accessibilityRequired
    case targetUnavailable
    case sourceChanged
    case selectionChanged
    case unsupportedEditableTarget
    case clipboardBusy
    case clipboardChanged
    case focusTimedOut
    case modifiersStillPressed
    case translationChanged
    case eventCreationFailed
}

nonisolated struct SelectedTextReplacementRequest: Equatable, Sendable {
    let operationID: UUID
    let sessionID: UUID
    let translationLookupID: UUID
    let sourceType: SentenceTranslationSource.SourceType
    let translatedText: String
}
```

编译时须确认 `SourceType` 的 Sendable 推导；若需要补充声明，只给该纯值枚举添加 `Sendable`，不要扩大并发豁免。

- `lookupID`：标识某一轮翻译，切语言或重译时改变。
- `sessionID`：标识最初被选中的输入目标，翻译请求改变时不变。
- `operationID`：标识一次按钮点击；决定异步结果能否更新当前 UI，并阻止重复提交。
- `SelectionHitTest.contextID`：用于鼠标命中和复制授权，不能兼任 replacement session ID。

`AppModel` 仅保存活动会话值、运行中的替换 Task 和反馈。AX 引用由 `SelectedTextService` 内部一个独立的 `ReplacementContext` 持有，继续限制在现有 probe executor 上，不传给 SwiftUI 或 MainActor。

### 4.2 译文完成状态

当前 LLM 的 `onPartialResult` 调用 `updateSentenceServiceTranslationResult(state: .ready(partialText), duration: nil, ...)`。因此 `.ready` 表示已有可展示文本，不能表示输出已经结束。

- 在 `ServiceTranslationResult` 增加 `isComplete: Bool = false`，并纳入其自定义 `Equatable` 实现。
- `makeServiceTranslationResult` 为新一轮结果初始化 false；partial 回调保持 false。
- 第三方 task 返回最终文本时，将同一结果的 `isComplete` 更新为 true；失败通过 `.failed` 保持不可替换。
- `updateSentenceServiceTranslationResult` 接收明确的完成参数，逐个更新 partial 与最终两个调用点；不从 `duration` 是否为空推导业务状态。
- 替换第三方结果要求 `.ready`、`isComplete == true`、当前 lookupID 和有效 session 同时成立。复制按钮沿用原有行为。
- 系统翻译只在完整返回时进入 `.ready`，同时仍需 `isRetranslating == false`，防止使用切语言过程中保留的旧文本。

### 4.3 内部替换上下文

`ReplacementContext` 至少包含：

- `sessionID`、来源进程 PID 和用于校验的应用标识。
- 最初文本控件、窗口及其身份；必要时保存最初焦点控件作为已验证文本代理。
- 有效的 UTF-16 `NSRange`，不能通过译文长度推算旧 range。
- `rawSelectedText`：原样保存，包含前后空格、换行、emoji、组合字符。
- 文本来源：AX 直接读取，或已授权的复制回退。
- 控件是否为前台可编辑目标的采集证据；提交时重新检查。
- 是否已消费或正在执行的操作标识。

只保留当前活动会话，不建立跨查询缓存。释放旧会话按具体 session ID 执行，旧任务返回不能清空新会话。

### 4.4 可编辑性判断

仅在以下条件共同成立时创建会话：

1. Direct capability 开启，辅助功能授权有效。
2. 当前最终路由确实采用该真实选区；沿用现有 pointer-scoped 规则。
3. 来源是触发时的前台应用；来源窗口与焦点控件能与文本候选证明一致。
4. 范围有效、长度大于 0，原始文字可验证。
5. 控件未明确禁用，且不是密码／安全输入控件；`AXEnabled` 不支持或无值时，仍必须有第 6 项的明确可写证据，其他读取错误则拒绝。
6. `kAXSelectedTextAttribute` 或 `kAXValueAttribute` 明确可写，作为首期保守的可编辑证据。

选区范围可设置、复制菜单可用或有 `AXTextArea` role，单独都不足以证明可编辑。AX 可写检测只用于资格判断，首期不执行 AX 文本写入。无法获得证据时只禁用替换能力，不能把已合法命中的选区退回 OCR。

2026-10-27 兼容修订：选区几何范围可缺失，可用时仍用于鼠标命中校验。原始范围必须有效，`AXStringForRange` 与 `AXSelectedText` 至少一个可读，且任何可读来源都必须与原文完全一致。鼠标命中 `contenteditable` 的文本子节点时，仅可采用其祖先链中同一窗口、当前获得焦点的编辑器；该编辑器必须提供可靠字符范围、完全一致的原文及明确可写证据。提交前继续复核保存的编辑器、窗口、范围及原文。

### 4.5 替换服务

创建 `SnapTra Translator/SelectedTextReplacementService.swift`，类型为 `@MainActor final class SelectedTextReplacementService`，由 MainActor 协调流程。核心接口是 `replace(request: SelectedTextReplacementRequest) async throws -> SelectedTextReplacementOutcome`，完整实现按 Task 5 和第 5 节定义的提交顺序编写。

构造器注入现有 `SelectedTextService`、剪贴板协调器，以及少量系统边界闭包：活动应用／按键状态、激活来源、发送事件、可取消等待。使用闭包或项目已有模式即可，不为每个 API 新建协议和抽象层。

AX 校验和短期结果确认仍由 `SelectedTextService` 提供 async 方法。MainActor 负责窗口、AppKit 和 NSPasteboard；等待使用可取消的 `Task.sleep`，不在主线程执行 `usleep` 或同步 AX 查询。

## 5. 替换流程与停止条件

### 5.1 正常提交顺序

1. `AppModel` 从当前 overlay state 重新解析按钮对应服务的完整结果；第三方同时检查 `isComplete`，系统翻译检查没有重译，不直接信任旧 View 捕获的字符串。
2. 冻结 `sessionID`、最新 `lookupID`、服务类型和译文；进入运行状态，使全部替换按钮暂时不可点击。
3. 检查渠道、当前授权、活动会话以及当前前台应用；其他应用正在前台时终止。
4. 从共享剪贴板协调器尝试获取独占操作权。繁忙时返回可重试反馈，不排队到未来再替换。
5. 在 AX executor 中检查原窗口、原控件、可编辑性、range 和原文仍匹配。
6. 暂时隐藏浮窗窗口，停止本次自动移动／关闭处理，但保留 overlay content 和会话；不能直接调用会清理上下文的 `dismissOverlay()`。
7. 如焦点被 SnapTra 面板接管，激活已验证的来源应用；有界等待原窗口和原控件恢复键盘焦点。
8. 等待用户松开 Command、Option、Control、Shift 等实际按住的修饰键，避免与触发翻译的按键叠加。
9. 如果原始文本只能通过复制获得，在同一剪贴板操作内重新复制并精确比对；这条复核不再要求鼠标仍位于原选区。
10. 再次检查会话、来源焦点、range、译文请求与剪贴板所有权；将译文写入剪贴板后立即复核其 `changeCount`。
11. 创建完整的一对 V down／up 事件，两者 flags 均为 `.maskCommand`；只发送一次粘贴，沿用现有 `.cghidEventTap` 路径。
12. 将会话标为已消费，避免重复操作；在有限时间内尝试读取原范围位置的译文，确认编辑器已经消费内容。
13. 已确认时恢复仍由本操作拥有的剪贴板、关闭浮窗；无法确认时返回 `pasteDispatched`，展示检查来源应用的反馈，保留译文供手动粘贴。

只要粘贴尚未发送，取消、权限变化、会话变化或来源变化都停止操作。V down 已发送后应完整发送 V up，再进入结果处理；不能在两个事件之间因取消而留下按键状态。

### 5.2 焦点恢复策略

- 来源应用相同不代表目标正确，必须检查 AX window 和 focused UI element。
- 来源应用仍在前台，也不代表 nonactivating panel 没有拿走键盘焦点；先隐藏 SnapTra 面板，再验证实际目标。
- 默认保持原选区，不发送鼠标点击、不重新设置过期 selected range。
- 用户已经切到同应用其他窗口或输入框时终止，不能为了完成操作切回旧窗口。
- 来源进程退出、窗口关闭、AX 引用失效，返回 `targetUnavailable`。
- 恢复过程中出现无关应用激活，或进入不同 Space 导致身份无法确认，取消本次操作。

焦点恢复初始预算设为 500ms，每 25ms 检查一次；实际仍受 AX 单次调用超时约束。替换专用 AX 引用使用短 timeout，建议从 100ms 起步；不要全局修改现有选区读取的 1.5s timeout。超时后停止，不能只等固定 60ms 就盲目粘贴。

修饰键释放初始预算为 500ms。仍按住时提示松开快捷键后重试，不替用户合成物理 Command key down／up。

### 5.3 复制回退的复核

AX 无法读取选中文字、但已由现有授权复制路径取得文本时：

- 创建会话前保存剪贴板取得的原始字符串及已证明的控件、窗口和 range。
- 提交前若 AX 仍无法读文本，在持有同一剪贴板 lease 时再模拟一次复制，最长等待 150ms。
- 复制前后均核对来源窗口、焦点、range、session ID 和取消状态；复制字符串与最初原始字符串必须完全一致。
- 不能调用当前要求 `NSEvent.mouseLocation == request.mouseLocation` 的读取授权方法来处理按钮点击；新增限定于已保存替换目标的复核，不放宽原自动取词的复制授权。
- 复核失败不写入译文、不粘贴、不搜索其他位置。

### 5.4 成功与未知结果

`CGEvent.post` 没有“编辑器已替换”的回执，接口返回不代表写回成功。

- 可验证：通过原元素的 `AXStringForRange` 读取原起点、译文 UTF-16 长度对应文本；能读到完整译文且目标身份有效时返回 `.verified`。
- 相同原文和译文可以作为无变化操作提前结束，不发送不必要的粘贴。
- 不可验证：范围读取不支持、超时或目标异步处理尚未完成，返回 `.pasteDispatched`。不显示“已替换成功”，不自动再粘贴。
- 初始验证预算 500ms，使用可取消等待，不增加常驻轮询。
- 发送后的取消只停止观察，不回滚来源编辑器，也不能触发第二次粘贴。

这是可观察性边界：跨应用 AX 校验与事件送达之间没有原子事务；短窗口内的竞态不能完全消除。通过临近提交的身份检查和一次性会话降低风险，实测记录这一限制。

## 6. 剪贴板协调

创建 `SnapTra Translator/PasteboardCoordinator.swift`，仅覆盖现有复制回退和本功能的粘贴，不把普通“复制译文”按钮改成排队服务。

- MainActor 上 `tryAcquire()` 返回不可重复释放的 lease ID；忙时返回 nil。
- 同一 lease 覆盖备份、可能的复制复核、写入译文、发送粘贴和完成处理。
- 复用现有所有可读取类型的 Data 备份方式，记录备份时和本操作每次写入后的 `changeCount`。
- `clearContents` 后写入失败也必须正确记录和清理自己的改动。
- 取消和失败释放 lease；释放要按 ID，旧任务的 `defer` 不能解锁新操作。
- 在等待中发现其他程序或普通复制按钮更改剪贴板时，提交前终止；恢复时不能覆盖该次外部写入。
- 已发出粘贴时，先确认消费结果再决定是否恢复：`.verified` 恢复自己的备份，`.pasteDispatched` 保留译文。这样避免恢复过早让迟到的粘贴读到旧内容。
- 取消发生在发送前，只要剪贴板仍归本操作所有就恢复；发送后不把取消当作可安全立即恢复的依据。
- 文件承诺、延迟提供数据和某些剪贴板管理器的历史记录不能保证完整还原，文档不承诺“剪贴板完全无痕”。

现有复制回退遇到 lease 繁忙时返回 nil，由既有路由继续使用 OCR；不得与粘贴同时向全局剪贴板写入。若普通复制按钮在提交期间更改内容，changeCount 校验会停止提交，保持用户的新复制内容。

## 7. 浮窗焦点与会话生命周期

### 7.1 焦点

- 保留 `OverlayPanel.canBecomeKey == true`，支持用户明确选择译文或编辑原文。
- 为 selected-text 有效替换会话的面板设置 `becomesKeyOnlyIfNeeded`，允许按钮第一次点击响应。
- `setInteractive` 新增是否请求键盘焦点的明确参数；普通 OCR、手动输入继续沿用原有行为。
- 同步审查 `show(makeKey:)`、`updateOverlay`、`keepOverlayAfterTap`、pin 和异步译文更新，避免后续更新再次无条件 `makeKey()`。
- 如需替换 NSHostingView 以控制 `acceptsFirstMouse` / `needsPanelToBecomeKey`，只影响本面板；原生文本控件仍可在点击时请求键盘焦点。
- 原文编辑器为 selected-text 初次显示增加 `automaticallyFocus: false`；用户明确展开编辑或点击编辑区时聚焦，并使替换会话失效。

### 7.2 生命周期表

| 事件 | 跟踪用 selection context | replacement session | 正在进行的替换 |
| --- | --- | --- | --- |
| 鼠标持续移动的选区复查 | 按现有规则保留／释放 | 当前结果有效时保留 | 提交期间暂停重新路由 |
| 松开快捷键但气泡按现有设置保留 | 可停止跟踪并释放 | 保留 | 不因松键误取消 |
| 固定结果面板 | 停止连续跟踪 | 保留 | 保持一次提交 |
| 切换目标语言 | 旧跟踪数据按原规则处理 | 保留同一 session ID | 提交前旧结果失效 |
| 修改 SnapTra 原文／进入编辑模式 | 按既有编辑行为 | 失效 | 发送前取消 |
| 新查询、切到 OCR、开始框选 | 释放旧 lookup 的 context | 释放旧 session | 发送前取消；旧回调不得污染新结果 |
| 关闭气泡、Esc、来源应用退出 | 释放 | 释放 | 发送前取消 |
| 切到其他应用／同应用另一个目标 | 按原规则 | 失效 | 发送前取消 |
| 休眠、权限撤销 | 按原规则 | 失效 | 发送前取消 |
| 替换服务暂时隐藏窗口 | 不作为新查询清理 | 保留 | 继续 |
| 粘贴已发出 | 可释放 | 消费并禁止再次提交 | 有界观察；不自动重试 |

切换语言改变 `activeLookupID` 时不能误删 session；session 不得允许旧 `lookupID` 的结果点击写回。两项约束分别测试。

## 8. 实施任务

每个 Task 是可审查的工作单元；其中每一步执行单一动作。行为变化先写能证明错误后果的测试，再实现；纯文案、布局和工程注册通过现有检查验证，不为它们新建镜像实现的测试。

### Task 0：记录基线与兼容接入点

**Files:**

- Read: `AGENTS.md`。
- Read: `docs/plans/2026-10-26-pointer-scoped-selection-translation-plan.md`。
- Read: `SnapTra Translator/SelectedTextService.swift`。
- Read: `SnapTra Translator/SelectedTextProbeExecutor.swift`。
- Read: `SnapTra Translator/AppModel.swift`。
- Read: `SnapTra Translator.xcodeproj/project.pbxproj` 和两个 shared schemes。

**Step 1:** 记录 `git status --short`、`git diff --stat` 和 HEAD，确定已有修改的归属。

**Step 2:** 在当前工作树运行现有最相关的基线测试：

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Debug \
  -destination 'platform=macOS' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextLookupRoutingTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextProbePolicyTests' \
  '-only-testing:SnapTra TranslatorTests/SinglePressLookupCoordinatorTests' \
  test CODE_SIGNING_ALLOWED=NO
```

预期：测试确实被发现并执行，成功时有 `TEST SUCCEEDED`。已有失败记录为基线问题，不用屏蔽测试伪造通过。

**Step 3:** 确认当前源码没有 replacement session／pasteboard lease；如果同期实现已加入同等能力，复用其能力，更新本文映射，避免两套实现。

**Step 4:** 固定手工测试文本、来源应用版本、OS、快捷键和显示器布局；仅使用可丢弃的测试文档和输入框。

### Task 1：建立纯值模型与提交规则

**Files:**

- Create: `SnapTra Translator/SelectedTextReplacement.swift`。
- Create: `SnapTra TranslatorTests/SelectedTextReplacementTests.swift`。
- Modify: `SnapTra Translator.xcodeproj/project.pbxproj`，只注册新增测试文件。
- Modify when required: `SnapTra Translator/SettingsStore.swift` 的 `SentenceTranslationSource.SourceType` Sendable 声明。

**Step 1:** 为 eligibility、目标一致性、单次消费和结果有效性增加失败测试。固定输入包括：同 PID 不同窗口、相同文本不同控件、range 为空、unknown range、原文仅空格变化、emoji／组合字符、App Store capability、过期 lookupID、重复 operation。

**Step 2:** 加入第 4 节模型和小型纯策略。目标一致性使用所有身份、范围和原始文本证据，不只比较字符串或 bundle ID。

**Step 3:** 为“翻译可用但无法替换”增加回归断言，保证不可编辑性不影响选区翻译。

**Step 4:** 运行新增 suite：

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Debug \
  -destination 'platform=macOS' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementPolicyTests' \
  test CODE_SIGNING_ALLOWED=NO
```

预期：新增 suite 执行且通过；所有禁止提交的输入都没有产生“允许粘贴”的决策。

### Task 2：采集原始文字，建立独立 AX 会话

**Files:**

- Modify: `SnapTra Translator/SelectedTextService.swift`。
- Modify: `SnapTra Translator/SelectedTextProbeExecutor.swift`。
- Modify: `SnapTra TranslatorTests/SelectedTextPerformanceTests.swift`。
- Modify: `SnapTra TranslatorTests/SelectedTextReplacementTests.swift`。

**Step 1:** 在 probe 测试中构造原文 `"  A👩🏽‍💻e\u{301}\n"`，断言翻译仍取得规范化文本，上下文保存原始字符串和原 range；`.outside` 候选不得创建会话。

**Step 2:** 在现有 probe policy 中保留 `rawResolvedText`；上下文同时保存 raw 和现有 normalized 字符串，保持当前连续跟踪比较语义。

**Step 3:** 为最终采用的 selected-text 路由提供 `prepareReplacementSession`，验证焦点、可编辑性和来源窗口后，把必要 AX 引用独立保留。未采用候选、只读候选和取消任务不能留下会话。

**Step 4:** 增加按 session ID 的校验、消费、释放和范围读取方法；直接文本不可读时保留受限复制复核模式。旧 session 的释放不能删除新 session。

**Step 5:** 执行新增会话测试和原 probe／executor 测试。断言 AX 工作仍不在主线程、最大并发仍为 1、未命中候选不会触发新增替换查询。新增的可编辑性检查只针对最终采用候选执行一次。

### Task 3：让复制回退与粘贴互斥

**Files:**

- Create: `SnapTra Translator/PasteboardCoordinator.swift`。
- Modify: `SnapTra Translator/SelectedTextService.swift` 的复制回退、备份与恢复。
- Modify: `SnapTra TranslatorTests/SelectedTextReplacementTests.swift`，加入 `PasteboardCoordinatorTests`。

**Step 1:** 增加测试：持有 lease 时第二次获取失败、取消后释放、错误路径释放、旧 lease 不能释放新 lease、多类型内容恢复、外部 changeCount 改变时不恢复。

**Step 2:** 实现共享 lease 与现有备份逻辑迁移，所有 NSPasteboard 访问留在 MainActor；测试使用命名 pasteboard 或 fake，不访问系统 general pasteboard。

**Step 3:** 将原 `clipboardSelectionSnapshot` 纳入 lease。copy fallback 遇到忙时返回 nil，维持既有 OCR 回退；保持原来源和鼠标授权校验。

**Step 4:** 为替换预留同一 lease 下的再次复制、写译文、验证后恢复和未验证保留策略。覆盖写入失败及取消发生在 copy 结束与读取之间的恢复。

**Step 5:** 运行 `PasteboardCoordinatorTests`、`SelectedTextClipboardPolicyTests` 与 `SinglePressLookupCoordinatorTests`，确认互斥不改变选区路由准入。

### Task 4：分开浮窗鼠标交互与键盘焦点

**Files:**

- Modify: `SnapTra Translator/OverlayWindowController.swift`。
- Modify: `SnapTra Translator/OverlayView.swift` 的原文编辑器聚焦。
- Modify: `SnapTra Translator/AppModel.swift` 的 overlay 呈现调用。
- Modify: `SnapTra TranslatorTests/ParagraphOverlayLayoutTests.swift`。

**Step 1:** 为焦点决策增加行为测试：有效 selected-text 会话初次呈现和译文更新不请求键盘焦点；明确进入编辑时可以请求；普通 OCR／手动输入沿用原策略。

**Step 2:** 为 `setInteractive` 提供显式焦点参数，接入 `becomesKeyOnlyIfNeeded` 和首次鼠标点击处理，不把所有浮窗设为不可成为 key。

**Step 3:** 调整 selected-text 初次展示、短按保留、固定和异步更新调用，避免重复抢焦点；为编辑器增加明确的自动聚焦输入。

**Step 4:** 保留短按浮窗既有鼠标保护；实测从选区移动至替换按钮。若途中触发持续翻译重新路由，只给有效替换会话增加必要的面板入口保护，并写对应行为测试。

**Step 5:** 运行 `ParagraphOverlayLayoutTests` 和 `SelectedTextContinuousLookupTests`；在 Direct 版手工确认复制按钮首次点击、译文文本选择和原文编辑仍能使用。

### Task 5：实现有界焦点恢复与一次粘贴

**Files:**

- Create: `SnapTra Translator/SelectedTextReplacementService.swift`。
- Modify: `SnapTra Translator/SelectedTextService.swift` 的替换专用校验方法。
- Modify: `SnapTra TranslatorTests/SelectedTextReplacementTests.swift`，加入 `SelectedTextReplacementServiceTests`。

**Step 1:** 用 fake 系统边界写失败测试：源窗口不匹配、焦点不恢复、复制复核不匹配、物理修饰键未释放、事件创建失败、点击后立刻取消、等待中 session 失效、提交前 clipboard 被改写，全部断言没有发送粘贴。

**Step 2:** 按第 5 节顺序实现 preflight、短 timeout 的 AX 检查、可取消轮询、同一 lease 内复制复核、写入和临近提交校验。不要把整个 `replace` 标成 `nonisolated` 后跨线程调用 AppKit。

**Step 3:** 实现一次 V down／up；发送前构造两个事件，任一创建失败都不发送。发送期间不插入可取消的悬挂点，不模拟 Return 或消息发送。

**Step 4:** 实现 `.verified`／`.pasteDispatched` 分流和相应剪贴板恢复。对已发送但无法验证的操作禁止自动重试。

**Step 5:** 运行 service suite，重点检查交错顺序和副作用计数。测试使用可控等待闭包或 continuation，不依赖真实 500ms sleep、AX 权限或键盘输入。

### Task 6：接入 AppModel 生命周期和结果绑定

**Files:**

- Modify: `SnapTra Translator/AppModel.swift`。
- Modify: `SnapTra TranslatorTests/SelectedTextReplacementTests.swift`，加入 `SelectedTextReplacementLifecycleTests`。
- Modify: `SnapTra TranslatorTests/ParagraphOverlayLayoutTests.swift` 中相关保留规则。

**Step 1:** 测试“切语言保留 session 但旧译文不可提交”“关闭结果后旧操作不能影响新结果”“停止跟踪不删除有效替换会话”“开始编辑立即失效”“LLM `.ready` partial 不可替换而最终结果可以”。优先测试小型会话状态与协调逻辑，不构造依赖真实权限和网络的 AppModel。

**Step 2:** 在最终选中文本路由采用后、浮窗取得交互能力前，准备并保存会话；按当前 source window 绑定元数据，不能在面板显示之后用 frontmostApplication 反推目标。

**Step 3:** 按第 4.2 节增加 `ServiceTranslationResult.isComplete`，更新相等比较、新请求初始化以及 partial／最终回调；新增 `replaceSelectedText(using:)` 一类入口，服务类型使用现有 `.native`／第三方 `SourceType`。从当前 state 取对应完整译文，复核最新 lookupID；异步 callback 同时核对 session 和 operation ID。

**Step 4:** 接入第 7 节生命周期表；提交期间暂时隐藏窗口并暂停鼠标自动路由，失败时只有原 overlay 仍有效才能恢复，恢复时不抢焦点。应用切换通知不能把本服务返回原来源应用误判为切换到无关应用。

**Step 5:** 确保关闭、休眠、权限变化、新查询和手动输入都能清理；保存并取消本服务 Task，取消后的 `defer` 必须释放 lease。

### Task 7：译文按钮、反馈与本地化

**Files:**

- Modify: `SnapTra Translator/OverlayView.swift`。
- Modify: `SnapTra Translator/Localizable.xcstrings`。
- Modify: `SnapTra Translator/AppModel.swift` 的用户可见反馈映射。

**Step 1:** 在系统 `.ready` 结果和第三方 `.ready` header 的复制按钮旁加入共享的小型替换按钮。使用现有样式，不重构整个结果面板。

**Step 2:** 由会话、当前渠道、结果完成状态和运行状态决定展示／可用性；retranslation 期间不能替换仍可见的旧系统结果，第三方流式结果使用显式 `isComplete`，不以 `.ready` 或 `duration` 代替完成判定。

**Step 3:** 提供清晰 label、help 和 accessibility label；可以在 help 中显示来源应用名称，面板内部不暴露 PID、AX 或 lookupID。

**Step 4:** 本地化以下语义，覆盖现有 en、zh-Hans、zh-Hant、ja、ko；已有相同 key 则复用：

| 英文 key | 简体中文 |
| --- | --- |
| `Replace Original` | 替换原文 |
| `Replacing…` | 正在替换… |
| `The original text or selection changed. Select it again.` | 原文或选区已变化，请重新选择。 |
| `Unable to restore the original input focus.` | 无法恢复原输入框焦点。 |
| `Release the shortcut keys and try again.` | 请松开快捷键后重试。 |
| `Clipboard is busy. Try again.` | 剪贴板正忙，请重试。 |
| `Replacement was sent. Check the original app.` | 已发送替换，请检查原应用。 |

**Step 5:** 错误在当前结果附近显示，保留复制能力；涉及目标变化的错误使会话失效。`.pasteDispatched` 不出现成功图标，不自动再次启用替换。纯 UI 和文案用构建、JSON 校验和手工检查验证，不新增截图快照测试。

### Task 8：回归测试、双渠道构建与说明

**Files:**

- Modify: `README.md`。
- Modify: `README.zh-CN.md`。
- Modify: `docs/README.md`。
- Modify: `docs/README.zh-CN.md`。
- Modify: `CHANGELOG.md`，仅在现有 Unreleased 位置追加本功能。
- Create: `docs/qa/2026-10-27-selected-text-replacement.md`，执行验收时填写实际结果。

**Step 1:** 执行第 9 节全部新增 suite 和最相关回归 suite。明确 App Store capability false 时不会调用激活、剪贴板或键盘边界。

**Step 2:** 分别构建两个 Release 渠道，避免 scheme 相同产品名导致构建产物混淆；授权态验证使用单独可定位的 Direct 构建路径。

**Step 3:** 记录现有 probe 性能结果与新增结果的差异。替换资格查询只发生在最终选区被采用后；不新增常驻 observer 或轮询，不降低原路由的命中要求。

**Step 4:** 更新使用说明：Direct 专属、编辑框内真实选区、多个译文可各自替换、普通 ⌘Z 撤销、原文变化需重选、未知消费结果保留译文。文案只声明验收通过的应用范围。

**Step 5:** 运行字符串目录 JSON 校验和 `git diff --check`，核对 diff 仅包含本功能必要内容；检查点不自动 commit 或发布。

### Task 9：授权态实测与首期交付判断

**Files:**

- Update: `docs/qa/2026-10-27-selected-text-replacement.md`。
- Update if needed: 本计划中的已知限制与已验收应用范围。

**Step 1:** 在具备辅助功能授权的 Direct 版，用可丢弃内容执行第 10 节矩阵。未安装的应用标记“未验证”，不记为通过。

**Step 2:** 对失败应用区分“未获取替换资格”“焦点／range 校验失败”“粘贴已发出但未应用”“结果无法验证”，记录 OS、应用版本、复现和日志原因码。

**Step 3:** 修复已声明支持场景中的问题；复现显示缺乏可靠身份或编辑证据的控件继续保留复制，不为扩大覆盖率放松一致性检查。

**Step 4:** 完成所有首期硬性标准后交付可审查 diff、测试摘要和兼容性记录；Enter 和 AX 直接写入留在后续范围。

## 9. 自动验证命令与关键断言

### 9.1 新增测试

建议在一个新测试文件中按职责放置以下 XCTestCase，避免过多工程注册改动：

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Debug \
  -destination 'platform=macOS' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementPolicyTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementSessionTests' \
  '-only-testing:SnapTra TranslatorTests/PasteboardCoordinatorTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementServiceTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementLifecycleTests' \
  test CODE_SIGNING_ALLOWED=NO
```

关键断言必须包含：

- 目标变化、缺权限、App Store、旧译文、取消：`pasteCallCount == 0`。
- LLM partial 即便是 `.ready`，只要 `isComplete == false` 就没有替换入口，也不能经模型入口发送粘贴；最终完成后才允许。
- 同会话重复点击、两个服务同时点击：`pasteCallCount == 1`。
- 外部 clipboard 写入后：不发送粘贴，不恢复旧内容。
- focus mismatch：即便 PID 一样也不粘贴。
- 未验证结果：outcome 是 `.pasteDispatched`，不能是 `.verified`，也不会自动重试。
- 发送前取消会恢复自己拥有的剪贴板；发送后未知结果不提前恢复。
- 新会话创建后旧操作完成：新会话、结果和按钮状态不被清空。

### 9.2 相关回归

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Debug \
  -destination 'platform=macOS' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextLookupRoutingTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextProbePolicyTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextProbeExecutorTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextClipboardPolicyTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextContinuousLookupTests' \
  '-only-testing:SnapTra TranslatorTests/SinglePressLookupCoordinatorTests' \
  '-only-testing:SnapTra TranslatorTests/ParagraphOverlayLayoutTests' \
  '-only-testing:SnapTra TranslatorTests/HotkeyManagerTests' \
  test CODE_SIGNING_ALLOWED=NO
```

预期：suite 均被执行且 `TEST SUCCEEDED`。`CODE_SIGNING_ALLOWED=NO` 用于编译和纯逻辑测试，不用于证明授权态跨应用输入可用。

### 9.3 渠道构建与静态检查

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator Direct" -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

python3 -m json.tool "SnapTra Translator/Localizable.xcstrings" > /dev/null

git diff --check
```

预期：两次 `BUILD SUCCEEDED`；JSON 校验和 diff 检查退出码 0。测试期间意外改动 App Store entitlement 或 Direct distribution 配置应视为偏离范围。

## 10. 手工验收矩阵

### 10.1 编辑器覆盖

| 类别 | 优先应用 | 需要验证 |
| --- | --- | --- |
| 原生文本 | TextEdit 纯文本 | 单行、多行、局部选区替换、一次 ⌘Z 撤销 |
| 原生富文本 | TextEdit 富文本、Notes | 仅改选区，周围文本不变；记录目标应用如何继承格式 |
| Web 表单 | Safari、Chrome 的 input／textarea | 焦点恢复、DOM 变化、第二窗口同 PID 不误替换 |
| Web 富文本 | 可丢弃 contenteditable 测试页 | input/change 处理、撤销、换行和 emoji |
| Electron 编辑器 | VS Code 可丢弃文本 | 编辑器 AX 暴露和粘贴处理；不可支持时明确记录 |
| 聊天输入框 | Slack／微信测试草稿 | 仅替换，不发送；不触发 Enter，不进入真实对话发送流程 |
| 终端 | Terminal／iTerm2 | 默认不能把可复制输出当可替换输入；仅在能证明编辑区时单独验证 |
| 只读选区 | 网页正文、Preview PDF | 可翻译和复制；没有替换按钮、没有粘贴事件 |

使用包含前后空格、多行、制表符、中文、英文、emoji 和组合字符的固定测试文案。混合文本示例：`  请确认 A👩🏽‍💻é 的版本\n第二行\tend  `，测试时输入实际换行和 tab。

### 10.2 交互与竞态

1. 短按保留气泡后移动至按钮，首次点击即可执行。
2. 按住快捷键显示结果后点击，未松修饰键不发送错误组合键。
3. 系统译文、第三方译文和同时启用两个服务分别替换正确内容。
4. 切换语言，旧系统译文仍显示时不可替换；新结果完成后可以。
5. 在面板编辑原文并重译，原外部选区不能被该结果替换。
6. 来源选区缩小、扩大、取消或原文仅空白变化，都停止操作。
7. 同应用窗口 A 选中后切窗口 B，不向 A 或 B 粘贴；不同应用同样处理。
8. 点击替换后立即关闭窗口、切应用、休眠或撤销授权，不向新焦点发送粘贴。
9. 连续点击替换以及两个服务结果交替点击，只产生一次写入。
10. 原剪贴板为文字、RTF、图片或文件列表时，已验证消费后按能力恢复；期间用户新复制的内容保留。
11. 模拟慢响应或不可读取结果的控件，呈现“已发送替换”而不是成功，不自动再粘贴。
12. 多显示器、缩放、全屏、不同 Space 下验证来源身份和失败路径，不按坐标猜测来源控件。
13. App Store 版打开相同设置和结果，仅有原有操作，无替换入口和新权限提示。

## 11. 硬性完成标准

- TextEdit 纯文本、至少一个浏览器标准输入框通过正常替换和一次撤销验收。
- 所有禁止场景的自动测试都证明没有发送粘贴；手工目标变化不误写其他窗口。
- 多翻译结果明确替换用户所选译文；重译与旧结果没有串用。
- 复制回退与粘贴不并发写全局剪贴板，所有退出路径释放 lease。
- 没有给只读／OCR／unknown range 结果虚构可写回目标。
- 双渠道 Release 构建和相关 XCTest 通过，App Store 行为保持原渠道能力。
- 保留现有鼠标命中、持续翻译、文本选择、编辑原文、复制与浮窗关闭行为。
- 不以“事件已发送”宣称“原文已修改”，不能自动重试不确定的粘贴。
- 实测报告注明已通过、失败与未验证的应用和系统版本；不宣称所有编辑器都支持。

## 12. 阶段安排与后续扩展

以下为熟悉 macOS／Swift 工程师的工作量估算，不含等待设备、权限环境或并行任务合并的时间。

| 阶段 | 任务 | 预计时间 | 可审查产物 |
| --- | --- | --- | --- |
| M0 | Task 0–1：基线与行为模型 | 0.5 天 | 明确首期范围、失败用例、值类型与规则 |
| M1 | Task 2–3：会话采集与剪贴板互斥 | 1–1.5 天 | 精确来源上下文、复制／粘贴不互相覆盖 |
| M2 | Task 4–5：焦点与粘贴服务 | 1–1.5 天 | 可验证的一次提交，完整取消／超时路径 |
| M3 | Task 6–7：生命周期与 UI | 0.5–1 天 | 可使用的系统／第三方译文替换按钮 |
| M4 | Task 8–9：回归与授权态验收 | 1–1.5 天 | 双渠道构建、测试摘要、应用兼容性记录 |

首期完整交付约 4–6 个工作日。M1、M2 中间状态不单独发布，必须连同 UI、取消路径和渠道限制一起验收。

后续独立评估：

1. **替换快捷键，约 1–2 天加应用验收。** 先确定使用组合键还是裸 Enter。需要专门 Event Tap 吞掉原事件；仅在有效会话、已完成指定译文、来源仍匹配、没有编辑原文／输入法组词时启用。多个译文要定义默认服务；不得复用只能观察事件的全局 NSEvent monitor，也不得让回车继续传到聊天应用。
2. **AX 直接替换优化，约 0.5–1 天加兼容性验收。** 只针对明确支持 `kAXSelectedTextAttribute` 写入的控件试点，验证 undo、富文本和应用输入事件。调用结果不明确时不能立即接着粘贴，避免重复修改；不改写完整 `AXValue`。
3. **App Store 替代交互，另立方案。** 可研究用户主动调用的 macOS Services／扩展，但需要独立验证能力和体验，不作为给现有沙盒添加普通权限即可完成的工作。

## 13. 参考

- 原机制：`/Users/yelog/workspace/swift/swapr-trans/Sources/SwaprTransKit/HUD/TranslationHud.swift` 的 `replaceSelection`、`postCmdVPaste`、`NonActivatingPanel`。
- 选区命中约束：`docs/plans/2026-10-26-pointer-scoped-selection-translation-plan.md`。
- [NSPanel.becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)。
- [NSView.needsPanelToBecomeKey](https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey)。
- [AXUIElementIsAttributeSettable](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable)。
- [NSEvent.addGlobalMonitorForEvents](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))。
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)。
