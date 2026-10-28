# Held Hotkey Text Replacement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复长按快捷键显示选中文本翻译时无法替换的问题：点击替换后等待用户松开修饰键，再对原始选区执行一次替换，期间不会被普通松键清理取消，也不会被后台译文更新重新打开浮窗。

**Architecture:** 复用 `HotkeyManager` 的修饰键监听，增加消费当前手势和观察全部修饰键变化的能力；用一个小型 MainActor 协调器集中管理待松键请求、执行任务与过期回调。`AppModel` 继续负责翻译结果、目标会话和窗口，`SelectedTextReplacementService` 继续负责焦点、AX 校验与一次模拟粘贴；等待用户松键发生在获取剪贴板锁之前。

**Tech Stack:** Swift 6、SwiftUI、Combine、AppKit、ApplicationServices、CoreGraphics、Swift Concurrency、XCTest；macOS 14+，系统翻译沿用 macOS 15+ 限制；不新增依赖。

**状态：** 2026-10-28 编写，基线 HEAD 为 `b6cc5cb`，编写前工作树干净。本轮只新增计划文档，未实施功能、未运行构建或测试。上方技能引用是计划模板；执行环境没有该技能时，按本文任务顺序执行，不因此安装技能或阻塞。各任务以审查检查点收尾；commit、push 和发布不属于本次授权。

---

## 1. 问题与代码证据

用户已确认：短按快捷键后常驻的句子翻译框可以替换；持续按住快捷键时点击替换无法正常完成。

| 接入点 | 当前行为 | 对长按场景的影响 |
| --- | --- | --- |
| `SnapTra Translator/SelectedTextReplacementService.swift`，`replace`，约 66 行 | 先隐藏浮窗，再处理焦点和修饰键 | 用户看不到正在等待松键 |
| 同文件，约 96–105 行 | 最多等待修饰键释放约 500ms，超时抛出 `modifiersStillPressed` | 点击后继续按住，会失败并恢复浮窗 |
| `SnapTra Translator/HotkeyManager.swift`，`handleReleaseResolution` / `scheduleReleaseCallback`，约 262 行 | 长按松键后，延迟约 150ms 调用 `onRelease` | 替换任务执行期间仍可能收到普通关闭回调 |
| `SnapTra Translator/AppModel.swift`，`finishHotkeyRelease`，约 697 行 | 非固定长按浮窗会取消查询并调用 `hideOverlay` | 间接取消替换任务，释放替换上下文 |
| 同文件，`clearSelectedTextReplacementSession`，约 2513 行 | 取消 `selectedTextReplacementTask` 并释放原选区上下文 | 松键可能打断正在准备提交的替换 |
| 同文件，`updateOverlay`，约 3037 行 | 段落结果更新时，窗口不可见便重新显示 | 其他翻译源返回可能让隐藏窗口重显 |
| 同文件，`replaceSelectedText`，约 2459 行 | `.pasteDispatched` 显示反馈并重新打开浮窗 | 已发送但 AX 未确认时也会重显 |

这里已确认的是源码中的冲突路径；尚未通过运行日志确定用户某次操作最终走的是超时、取消还是未确认分支。实施验收需覆盖这些路径，不能只检查按钮可点击。

## 2. 交互与范围

### 2.1 目标行为

| 场景 | 目标行为 |
| --- | --- |
| 常驻浮窗，当前未按修饰键，点击已完成译文的替换按钮 | 立即启动现有提交流程 |
| 按住 Right Option 点击替换 | 浮窗保持可见，提示“松开快捷键以替换”，全部替换按钮禁用 |
| 点击后继续按住 1 秒、3 秒或更久 | 保持待松键状态，不因 500ms 超时失败，不占用剪贴板 |
| 松开全部相关修饰键 | 消费本次手势的普通松键动作，隐藏浮窗，重新校验目标后仅发送一次粘贴 |
| Right Option 已松开，但 Left Option / Command / Shift / Control / Fn 仍按住 | 继续等待，直到所有相关修饰键释放 |
| 没有点击替换，正常长按后松开 | 保持原有关闭行为 |
| 等待期间按 Esc、关闭浮窗、点击浮窗外或开始新查询 | 取消待执行请求；之后松键不能触发旧替换 |
| 等待期间切到其他应用、来源退出、休眠、快捷键设置变化 | 取消待执行请求，不自动恢复或提交 |
| 替换前发现选区、原文、来源窗口或控件已变化 | 不粘贴；当前结果仍适用时显示明确失败原因 |
| 已发出粘贴且得到 `.verified` | 结束当前会话，保持浮窗关闭 |
| 已发出粘贴但只能得到 `.pasteDispatched` | 同样结束当前会话、保持关闭；记录未确认结果，不声称成功、不自动重试 |

“等待松键”必须由明确的替换点击创建。不能在普通翻译完成或普通松键时创建替换请求。

### 2.2 本次范围

- 覆盖 Direct / GitHub 版的选中文本句子替换，以及它与现有长按、短按常驻和固定面板的交互。
- 保留渠道检查、完整译文要求、原控件身份和精确选区校验。
- 修复替换期间的后台更新重显，以及已发送结果结束浮窗的行为。
- 修正未确认发送时过早恢复旧剪贴板的问题。
- 不增加设置项，不重写翻译链路，不扩展浏览器或微信兼容性，不改成盲目向当前光标粘贴。
- 不通过增大 500ms、禁用全部热键监听或自动固定面板来解决生命周期冲突。

## 3. 状态、事件与所有权

### 3.1 请求快照

在 `SnapTra Translator/SelectedTextReplacement.swift` 增加以下值类型。下列名称是拟新增 API，不是已有实现：

```swift
struct SelectedTextReplacementRequest: Equatable {
    let operationID: UUID
    let session: SelectedTextReplacementSession
    let lookupID: UUID
    let sourceType: SentenceTranslationSource.SourceType
    let translatedText: String
}

enum SelectedTextReplacementPhase: Equatable {
    case waitingForModifiers
    case replacing
    case pasteDispatched
}

struct SelectedTextReplacementOperation: Equatable {
    let request: SelectedTextReplacementRequest
    var phase: SelectedTextReplacementPhase
}
```

请求和状态留在 MainActor，不为此扩大现有类型的 `@unchecked Sendable` 范围。`operationID` 区分点击，`session.id` 绑定原始输入目标，`lookupID` 绑定用户点击的那轮译文。

`translatedText` 在点击时从最新 `overlayState` 取出并冻结。等待期间其他服务返回结果，不能改变将要替换的文本。保留原文空格、换行和 UTF-16 选区的既有校验。

### 3.2 唯一操作所有者

新增 `SnapTra Translator/SelectedTextReplacementCoordinator.swift`，类型为 `@MainActor final class SelectedTextReplacementCoordinator: ObservableObject`：

- 唯一保存 `@Published private(set) var operation: SelectedTextReplacementOperation?`。
- 唯一持有执行替换的 `Task<Void, Never>?`；等待松键时不创建提交 Task。
- 提供 `submit(_:) -> Bool`、`modifiersDidChange()` 和 `cancel()`。
- `AppModel` 保留目标会话、译文、错误反馈和已消费会话集合；转发协调器的 `objectWillChange`，沿用项目已有 Combine 模式。
- 现有 `selectedTextReplacementOperationID` 改为从协调器状态派生；移除 AppModel 中独立的同名存储和 `selectedTextReplacementTask`，避免两套运行状态。
- 不再保留一个额外的 `isWaiting` 或全局 `ignoreNextRelease` 作为第二套状态。

协调器构造时注入六个 MainActor 边界闭包，测试可直接替换，不必实例化整个 AppModel 或注入真实键盘事件：

```swift
init(
    currentModifiers: @escaping @MainActor () -> NSEvent.ModifierFlags,
    consumeCurrentGesture: @escaping @MainActor () -> Void,
    isRequestCurrent: @escaping @MainActor (SelectedTextReplacementRequest) -> Bool,
    performReplacement: @escaping @MainActor (
        SelectedTextReplacementRequest,
        @escaping @MainActor () -> Void
    ) async throws -> SelectedTextReplacementOutcome,
    onPasteDispatched: @escaping @MainActor (SelectedTextReplacementRequest) -> Void,
    onCompletion: @escaping @MainActor (
        SelectedTextReplacementRequest,
        Result<SelectedTextReplacementOutcome, Error>
    ) -> Void
)
```

这些闭包只隔离当前功能的系统副作用，不引入通用事件总线、每个 API 一个协议或新的依赖注入框架。AppModel 的生产接线继续经过真实渠道和权限检查。

### 3.3 状态转换约定

| 当前状态 | 事件 | 下一状态与副作用 |
| --- | --- | --- |
| 无操作 | 接受替换点击，存在修饰键 | 保存请求，消费当前手势，进入 `waitingForModifiers`；窗口可见 |
| 无操作 | 接受替换点击，没有修饰键 | 保存请求，消费当前手势及已排队的松键动作，进入 `replacing` |
| `waitingForModifiers` | 任一修饰键变化，但当前系统状态仍有相关按键 | 保持等待 |
| `waitingForModifiers` | 当前系统状态中全部相关修饰键释放 | 检查请求仍有效，进入 `replacing` 并创建唯一 Task |
| `waitingForModifiers` / `replacing` | 重复点击或重复松键事件 | 不创建第二个请求或 Task |
| `replacing` | 服务已同步发送完整 V down / up | 立即进入 `pasteDispatched`，标记该会话已消费 |
| `replacing` | 发送前明确失败 | 清理操作后，向仍匹配的当前会话交付错误 |
| `pasteDispatched` | 返回 `.verified` / `.pasteDispatched` | 清理操作后结束当前浮窗和会话 |
| 任意活动状态 | 用户取消、来源失效或新查询 | 同步移除活动操作，再取消旧 Task；旧完成回调失效 |

每次候选松键事件都重新读取当前系统按键状态，不能只相信排队中的 `event.modifierFlags`。忽略 Caps Lock、Numeric Pad 等与粘贴无关的标志。

### 3.4 清理规则

- 取消先使 `operationID` 失效，再取消 Task。旧任务的 `catch`、`defer`、验证结果和屏幕恢复回调不能清空或显示新会话。
- 所有完成处理必须同时核对 `operationID`、`session.id`、`lookupID`；状态清理后的 AppModel 完成回调至少核对捕获的 session 与 lookup。
- 原始 AX context 按捕获的 `contextID` 释放，不从可能已经变化的当前会话中取 ID。
- 发送前取消：不发送粘贴，按所有权恢复本次写入的剪贴板。
- 发送后取消：不撤销、不重发、不立即恢复尚未确认被消费的剪贴板；允许旧服务完成有限收尾，但不再更新 UI。
- 失败显示出来的长按结果需使用现有短按保留机制转为可关闭、可复制的错误浮窗，不把普通未操作的长按结果自动保留。

## 4. Task 0：确认基线与可重复验证入口

**Files:**

- Read: `AGENTS.md`。
- Read: `docs/qa/2026-10-27-selected-text-replacement.md`。
- Read: `SnapTra Translator.xcodeproj/xcshareddata/xcschemes/SnapTra Translator.xcscheme`。
- Read: `SnapTra Translator.xcodeproj/xcshareddata/xcschemes/SnapTra Translator Direct.xcscheme`。

**Step 1:** 记录 `git status --short --branch` 与当前 HEAD；如果已有新修改，按实际符号重新确认接入点，保留用户改动。

**Step 2:** 使用文末命令 A 运行相关现有测试并保存基线日志；失败时先判断是否为已有问题。

**Step 3:** 确认测试入口：实际已有 `SnapTra TranslatorTests` target，仓库 AGENTS 的“无测试 target”描述已落后于工程；使用已有 target，不新建。Direct scheme 的 Testables 为空，不能用它声称 XCTest 已通过。

**Step 4:** 准备独立可丢弃的原生 NSTextView 测试窗口和最新 Direct Debug 应用。记录短按常驻可替换、长按点击后继续按住和及时松开两条基线，观察原文与粘贴次数。

**Checkpoint:** 留下可对照的测试与现象记录。不能将已有 QA 文档的历史结果当成本轮执行结果。

## 5. Task 1：编写协调器的行为回归测试

**Files:**

- Create: `SnapTra TranslatorTests/SelectedTextReplacementCoordinatorTests.swift`。
- Modify: `SnapTra Translator.xcodeproj/project.pbxproj`，注册新测试文件。
- Planned source: `SnapTra Translator/SelectedTextReplacement.swift`。
- Planned source: `SnapTra Translator/SelectedTextReplacementCoordinator.swift`。

**Step 1:** 注册测试文件。应用源目录使用同步 group，新源文件自动加入 app target；测试目录仍需 file reference、group child、build file 和 Sources phase 四处登记。

**Step 2:** 以可控修饰键值、可挂起的 async 执行闭包、记录调用次数和结果的闭包编写测试。测试不访问真实剪贴板、真实 AX 或网络。

| 必须覆盖的测试 | 关键断言 |
| --- | --- |
| `testHeldShortcutWaitsForReleaseBeforeReplacing` | 按键未松开时执行次数为 0；释放后为 1 |
| `testPersistentOverlayStartsReplacementImmediately` | 无修饰键时直接进入提交 |
| `testRemainingModifierKeepsRequestWaiting` | 目标键松开但另一修饰键仍按住时不提交 |
| `testQueuedReleaseChecksCurrentPhysicalModifiers` | 收到旧松键通知、实际已重新按住时不提交 |
| `testRepeatedClicksAndReleaseEventsDispatchOnce` | 连续点击、重复通知只接受一个请求 |
| `testCancelWhileWaitingPreventsLaterReplacement` | 取消后松键不执行 |
| `testChangedSessionOrLookupRejectsPendingRequest` | 会话或译文请求变化后不执行 |
| `testWaitingUsesClickedProviderText` | 后台结果变化不能替换请求中冻结的译文 |
| `testOldCompletionCannotFinishNewOperation` | 旧异步结果返回不清空新操作、不交付旧完成回调 |
| `testDispatchIsRecordedBeforeVerificationCompletes` | 验证尚未返回，已消费回调已恰好触发一次 |
| `testCancellationAfterDispatchDoesNotRetryOrReportSuccess` | 取消不会第二次调用服务，也不会交付旧 UI 结果 |
| `testPreDispatchFailureAllowsExplicitRetry` | 明确未发送的失败结束后，可接受用户的新点击 |

核心测试按以下方式构造；所有依赖均为拟新增协调器的正式接口：

```swift
@MainActor
func testHeldShortcutWaitsForReleaseBeforeReplacing() async {
    var modifiers: NSEvent.ModifierFlags = [.option]
    var consumeCount = 0
    var submittedTexts: [String] = []
    let completed = expectation(description: "replacement completed")
    let session = SelectedTextReplacementSession(
        id: UUID(),
        contextID: UUID(),
        sourceProcessIdentifier: 42,
        sourceApplicationName: "Fixture",
        rawText: "Hello",
    )
    let request = SelectedTextReplacementRequest(
        operationID: UUID(),
        session: session,
        lookupID: UUID(),
        sourceType: .native,
        translatedText: "你好",
    )
    let coordinator = SelectedTextReplacementCoordinator(
        currentModifiers: { modifiers },
        consumeCurrentGesture: { consumeCount += 1 },
        isRequestCurrent: { _ in true },
        performReplacement: { request, didDispatch in
            submittedTexts.append(request.translatedText)
            didDispatch()
            return .verified
        },
        onPasteDispatched: { _ in },
        onCompletion: { _, _ in completed.fulfill() },
    )

    XCTAssertTrue(coordinator.submit(request))
    XCTAssertEqual(coordinator.operation?.phase, .waitingForModifiers)
    XCTAssertTrue(submittedTexts.isEmpty)

    modifiers = []
    coordinator.modifiersDidChange()
    await fulfillment(of: [completed], timeout: 1)

    XCTAssertEqual(consumeCount, 1)
    XCTAssertEqual(submittedTexts, ["你好"])
    XCTAssertNil(coordinator.operation)
}
```

**Step 3:** 使用命令 B 运行新增测试，确认尚未实现类型或缺失行为导致失败；不得将测试未注册、执行 0 项当作预期失败。

**Checkpoint:** 回归要求已成为可执行测试；不为提示文字和图标编写镜像测试。

## 6. Task 2：实现唯一替换状态与任务调度

**Files:**

- Modify: `SnapTra Translator/SelectedTextReplacement.swift`。
- Create: `SnapTra Translator/SelectedTextReplacementCoordinator.swift`。
- Test: `SnapTra TranslatorTests/SelectedTextReplacementCoordinatorTests.swift`。

**Step 1:** 加入第 3 节的请求、阶段和操作值类型；协调器使用 AppKit、Combine 和 Foundation，不依赖 SwiftUI 窗口。

**Step 2:** 实现 `submit`：仅在空闲且请求当前有效时接受；在同一个 MainActor 同步片段内保存操作、消费手势并调用就绪检查。

**Step 3:** 实现唯一就绪入口 `modifiersDidChange()`：只处理 `waitingForModifiers`，重新读系统修饰键；全部释放且请求仍有效时，先同步把 phase 改为 `replacing`，再创建 Task，避免重复通知启动两次。

**Step 4:** 执行闭包返回之前的每个回调核对操作身份。发送回调先更新 phase，再调用 `onPasteDispatched`；完成先清理自己的 Task 与 operation，再交付 `onCompletion`。取消和过期结果不交付完成反馈。

**Step 5:** 实现 `cancel()`：同步取走并清空当前 operation / task，再取消旧任务。无活动操作时幂等；不直接清除 AppModel 的目标会话或操作来源应用。

**Step 6:** 用命令 B 使 Task 1 的测试通过。使用 continuation 控制“服务尚未完成”和“旧操作晚于新操作完成”，不靠任意 sleep 制造竞态。

**Checkpoint:** 等待期间没有提交 Task、剪贴板锁或 500ms 倒计时；执行期间只有一个 Task；旧结果无法影响新操作。

## 7. Task 3：让热键支持当前手势的显式移交

**Files:**

- Modify: `SnapTra Translator/HotkeyManager.swift`，`handleFlagsChanged`、`resetState`、`scheduleReleaseCallback`。
- Modify: `SnapTra TranslatorTests/HotkeyManagerTests.swift`。

**Step 1:** 先补失败测试，覆盖消费长按后不再产生普通 release、消费已排队的 release 后不回调、下一次按键正常触发、其他修饰键变化仍被观察，以及未消费手势的原有行为。

**Step 2:** 增加 `onModifierFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?`，在 `handleFlagsChanged` 的目标 keyCode 过滤之前通知。左右 Option、Command、Shift、Control 和 Fn 的变化均可唤醒协调器。

这个观察回调不能把“不匹配目标 keyCode”的事件当作新手势。原有物理左右键识别、组合键资格判断和重复 flagsChanged 去重继续保留。

协调器的 `currentModifiers` 生产闭包使用 `NSEvent.modifierFlags` 读取当前状态；目标物理键的跟踪仍使用现有左右键 mask。AppModel 不以 `isHotkeyActive` 代替物理按键状态。

**Step 3:** 增加 `consumeCurrentGesture()`，只清理手势语义和延迟回调，不伪造物理松键：

```swift
func consumeCurrentGesture() {
    invalidatePendingRelease()
    gestureStateMachine.reset()
    // isTargetKeyDown 保留，后续真实 flagsChanged 继续维护物理状态。
}
```

不得在这里调用当前 `resetState()`，因为它还会把 `isTargetKeyDown` 改为 false。重复的按下通知不能把仍按着的同一物理按键当成新查询。

**Step 4:** 为延迟 release 增加代次校验。`invalidatePendingRelease()` 在取消 work item 的同时递增代次；延迟闭包捕获代次，执行时先校验，消费手势、reset、stop 和新的有效手势都会使旧代次失效。

测试使用小型可注入 scheduler 捕获延迟动作，主动执行已失效动作验证不会回调，避免仅依赖 DispatchWorkItem 的取消行为。scheduler 的生产默认仍为 `DispatchQueue.main.asyncAfter`。

同时为重新安装的 NSEvent monitor 使用安装身份校验，丢弃旧安装已排入主队列的事件。消费手势不停止 monitor，因此仍能收到真正的松键。

**Step 5:** 执行命令 B 中的 HotkeyManager 测试及现有手势测试。确认短按双击窗口、Right Option 松开而 Left Option 仍按住、reset 后松键、不合格组合键等已有测试仍通过。

**Checkpoint:** 一次点击能明确消费本次手势及其迟到的关闭动作；下一次真实按下仍可开始新查询。

## 8. Task 4：接入 AppModel，覆盖长按与常驻入口

**Files:**

- Modify: `SnapTra Translator/AppModel.swift`，约 529 行的替换状态。
- Modify: 同文件，`replaceSelectedText`、热键回调绑定、`finishHotkeyRelease`、`handlePersistentSentenceOverlayRelease`。
- Modify: 同文件，`clearSelectedTextReplacementSession`、`restartHotkey`、设置和系统生命周期回调。

**Step 1:** 创建协调器并转发 `objectWillChange`。可使用私有 lazy factory，在所有 AppModel 存储初始化后绑定弱引用闭包；避免在初始化完成前捕获 self 或生成强引用环。

**Step 2:** 保留 `replaceSelectedText` 的渠道、权限、有效会话、完整结果及非空译文检查，再要求当前 `activeLookupID`，生成请求并提交给协调器。所有替换按钮共用一个操作入口。

`isRequestCurrent` 生产实现必须检查：

```swift
private func isReplacementRequestCurrent(
    _ request: SelectedTextReplacementRequest
) -> Bool {
    supportsSelectedTextTranslation
        && permissions.status.accessibility
        && activeLookupMode == .selectedTextSentence
        && selectedTextReplacementSession?.id == request.session.id
        && activeLookupID == request.lookupID
        && !consumedReplacementSessionIDs.contains(request.session.id)
}
```

该函数用于发送前有效性判断。发送回调已把 session 标为 consumed 后，结果收尾改用独立的操作 / session / lookup 身份匹配，不能再要求 `!consumed`，否则正常完成也会被自己拒绝。

**Step 3:** 接受替换点击后暂停本次鼠标跟踪、debounce 和自动移动关闭；保持 Esc 与显式关闭可用。等待阶段不隐藏窗口、不激活来源应用、不获取剪贴板锁。

**Step 4:** 将 `onModifierFlagsChanged` 接到协调器。真正开始执行时更新 `isHotkeyActive = false`，保留目标和译文，然后调用替换服务。普通和 persistent release 入口对当前活动替换做保护，不走 `hideOverlay`、`keepOverlayAfterTap` 或自动 pin 分支。

保护必须属于当前替换操作；不能永久设置一个全局忽略松键标志。热键端的代次校验负责处理操作结束后才到达的旧关闭动作。

**Step 5:** 将旧 `selectedTextReplacementTask` 取消点改接协调器。逐一检查下表，不用 grep 后批量机械替换：

| 事件 | 处理 |
| --- | --- |
| 新查询、OCR、手动框选 | 先取消旧操作，按既有逻辑释放旧 session，再开始新查询 |
| Esc、关闭、等待时点击窗外 | 取消并关闭；随后松键不重开 |
| 编辑原文 / 切语言 / 重译 | UI 在活动操作期间禁用；模型入口仍需在显式变更时使旧请求失效 |
| 激活无关应用 | 取消等待或发送前操作；不将用户拉回来源应用 |
| 来源应用终止 | 使用 `NSWorkspace.didTerminateApplicationNotification` 对保存 PID 取消并清理 |
| 权限状态变为不可用 | 取消发送前操作并结束等待状态；服务提交前仍检查实时权限 |
| 休眠、重置、快捷键设置变化 | 先取消再重置热键，避免待松键请求失去观察入口 |
| `restartHotkey()` | 活动替换期间不因普通应用激活重装 monitor；必要设置变更先取消 |
| 屏幕配置变化 | 取消待执行或发送前操作；删除旧“等 task 结束后直接重显”的路径，按捕获身份和是否已发送决定收尾 |

**Step 6:** 统一 session 清理：取消操作、同步清除目标会话和反馈、按原 contextID 异步释放。旧任务的完成和 cleanup 不得覆盖新操作。已有双重清理调用保持幂等。

**Checkpoint:** 常驻与长按共用同一替换服务；长按的松键已转交替换，不再与普通关闭竞争。

## 9. Task 5：控制窗口重显，呈现待松键状态

**Files:**

- Modify: `SnapTra Translator/AppModel.swift`，`updateOverlay`、`showOverlayWindowForActiveLookup`、`showSelectedTextReplacementFeedback`。
- Modify: 同文件，`handleParagraphOutsideMouseDown`、`syncOverlayDismissalMonitoring`。
- Modify: `SnapTra Translator/OverlayView.swift`，`paragraphResultView`、`replaceSelectedTextButton`。
- Modify: `SnapTra Translator/Localizable.xcstrings`。

**Step 1:** 从协调器状态派生 `isWaitingForSelectedTextReplacementModifiers` 和“当前浮窗正在替换而暂停显示”。后者须匹配 session / lookup，且 phase 为 `replacing` 或 `pasteDispatched`；waiting 不暂停正常内容显示。

**Step 2:** 在 `updateOverlay` 的自动窗口展示前检查该状态。当前替换执行期间允许发布同一 lookup 的内容更新，但跳过 show、makeKey、窗口交互设置和布局刷新。`showOverlayWindowForActiveLookup` 做同样的防御检查。

服务真正隐藏窗口时取消排队布局刷新；保留 `hideWindowOnly()`，不能在发送前调用会释放上下文的 `dismissOverlay()`。

**Step 3:** 错误恢复方法改为接收捕获的 request，核对 session 和 lookup；仅对发送前失败恢复窗口。禁止无身份的旧回调调用通用 show。长按已松开时，复用 `keepOverlayAfterTap()` 保留错误反馈，便于复制、关闭或重新选择。

对 `selectionChanged` / `targetUnavailable` 等需使原目标失效的错误，先核对当前 request 并确定可呈现错误，再清理替换上下文、保留该 lookup 的错误内容，最后恢复窗口；不能先清除 session，再因 session 不匹配而丢弃应显示的错误。如果前台已是无关应用，直接取消，不恢复旧浮窗。

**Step 4:** waiting 阶段在原反馈区域显示普通提示，替换按钮显示等待图标并禁用；executing 阶段沿用进度状态。提示与错误分别着色，避免将正常等待显示成失败。提供可访问性标签。

新增字符串 `Release shortcut keys to replace.`：en、zh-Hans、zh-Hant、ja、ko 均补齐，简体中文为“松开快捷键以替换”。不增加弹窗或系统通知。

**Step 5:** 等待期间保留复制与关闭，禁用替换、原文编辑、切语言及重译控件。将等待状态加入窗外点击监控的限定条件；只有活动等待操作使用这条取消规则，不扩展普通长按或 OCR 浮窗的关闭条件。

**Checkpoint:** 按住时点击不会闪烁；松开后才隐藏；迟到译文不会重新打开正在替换的窗口；发送前失败的说明可见且可关闭。

## 10. Task 6：明确提交时点与剪贴板收尾

**Files:**

- Modify: `SnapTra Translator/SelectedTextReplacementService.swift`，`replace`。
- Modify: `SnapTra Translator/PasteboardCoordinator.swift`，仅增加可注入的 pasteboard 存储边界。
- Modify: `SnapTra Translator/AppModel.swift`，替换完成处理。
- Modify: `SnapTra TranslatorTests/SelectedTextReplacementTests.swift`。
- Test: `SnapTra TranslatorTests/SelectedTextReplacementCoordinatorTests.swift`。

**Step 1:** 给服务增加 `onPasteDispatched: @MainActor () -> Void` 参数，在完整发送 V down / up 后立即同步调用。两次 post 之间不添加 await 或取消点，回调不能再次发出粘贴。

**Step 2:** 移除承担用户交互等待的 20 次修饰键轮询。服务在获取锁前检查相关修饰键全松开；在最后一次 await 校验返回后、无 await 的最终提交片段再检查一次。重新按下时返回 `modifiersStillPressed`，不带着物理修饰键发送粘贴。

焦点恢复仍保留有界等待，AX、当前应用、精确选区、剪贴板 changeCount 与取消校验继续执行。只把“等待用户慢慢松键”移到协调器，不放松提交资格。

**Step 3:** 派发后由协调器立即标记当前 session 已消费。在 AppModel 的两个已发送结果分支统一结束当前会话：`.verified` 和 `.pasteDispatched` 都保持浮窗关闭。未确认结果只记录诊断，不自动重试，也不显示“替换成功”。

**Step 4:** 剪贴板收尾采用以下确定规则：

| 情况 | 剪贴板行为 |
| --- | --- |
| 等待用户松键 | 不获取 lease，不读取或写入剪贴板 |
| 发送前失败或取消，本次已写入且仍拥有 changeCount | 恢复备份并释放 lease |
| 已发送，AX 确认译文被目标读取 | 仍拥有 changeCount 时恢复备份 |
| 已发送，验证超时、不支持或发送后取消 | 保留译文，只释放 lease，避免迟到粘贴读取旧内容 |
| 任意阶段外部应用改变剪贴板 | 保留外部新内容，不恢复旧备份 |

具体删除当前验证超时之后无条件尝试恢复备份的分支。不得在普通 `defer` 中对所有结果统一恢复。

**Step 5:** 为服务的系统边界使用小型可注入闭包测试最终提交条件与恢复策略，复用真实 production 控制流；不要用只断言常量映射的测试代替它。覆盖最终复核时再次按键、发送前取消、确认 / 超时 / 外部剪贴板变更，以及一次 down / up 后立即收到派发回调。

采用服务内嵌的 `Environment` 值保存边界闭包，生产工厂包装现有系统 API；至少隔离渠道 / 权限、前台 PID、来源激活、当前修饰键、AX 校验、结果读取、事件派发与等待。构造器默认使用生产环境，测试显式使用假环境；不通过修改 Bundle 配置或真实系统权限才能运行测试。

`dispatchPaste` 闭包的生产实现保留完整 CGEvent down / up 创建与同步发送，测试实现只记录派发次数。发送前后的恢复时机由真实 `replace` 流程决定，不能把该业务决策移到假环境。

`PasteboardCoordinator` 增加 `init(pasteboard: NSPasteboard = .general)`，所有备份、写入和恢复使用同一个存储；服务的 changeCount 检查也从该协调器读取，移除服务内部直接取 `.general`，避免检查与写入落在不同剪贴板。测试使用唯一命名 pasteboard，并在结束释放。

**Step 6:** 诊断只记录操作 ID、阶段、取消原因、结果类型和耗时。使用 `Logger`，不打印原文、译文、剪贴板内容或凭据。

**Checkpoint:** 物理修饰键未释放时无法提交；一个请求只派发一次；未确认不会重弹，也不会过早恢复旧剪贴板。

## 11. Task 7：运行自动回归与渠道构建

**Files:**

- Test: `SnapTra TranslatorTests/SelectedTextReplacementCoordinatorTests.swift`。
- Test: `SnapTra TranslatorTests/SelectedTextReplacementTests.swift`。
- Test: `SnapTra TranslatorTests/HotkeyManagerTests.swift`。
- Test: `SnapTra TranslatorTests/ParagraphOverlayLayoutTests.swift`。
- Test: 现有路由、probe 和请求测试。

**Step 1:** 使用命令 B 运行本次新增和直接相关测试，确认实际执行项数及 0 失败。

**Step 2:** 使用命令 A 扩展验证现有取词路由、短按保留和浮窗策略。新增 coordinator tests 也包含在最终回归中。

**Step 3:** 分别执行命令 C、D、E，验证 Direct Debug、Direct Release 和 App Store Release。不同产物使用不同 DerivedData，避免拿旧应用实测。

**Step 4:** 执行 `git diff --check`、字符串目录 JSON 校验和工程文件语法校验；检查没有新增依赖，没有破坏 App Store 的替换入口限制。

**Checkpoint:** 通过后进入实机验收，不在没有新失败或代码变化时反复重跑同一批构建。

## 12. Task 8：实机验收与文档交付

**Files:**

- Create: `docs/qa/2026-10-28-held-hotkey-text-replacement.md`。
- Update: 本计划的执行状态与结果。
- Update: `docs/plans/2026-10-27-selected-text-replacement-plan.md` 顶部交互修订，只追加与新结果行为相关的说明，保留历史记录。

**Step 1:** 在可丢弃原生 NSTextView 窗口执行下表。记录原文前后、真实 paste 次数、窗口最终可见性、modifier 等待与取消阶段。

| 编号 | 操作 | 验收标准 |
| --- | --- | --- |
| M1 | 短按常驻后替换 | 与基线一致，替换一次，浮窗结束 |
| M2 | 按住 Right Option 点击，继续按住 1–3 秒再松开 | 等待时不闪、不改剪贴板；松开后替换一次 |
| M3 | 点击后立即松开 | 不被迟到的普通 release 取消 |
| M4 | 点击时普通 release 已排队，随后替换很快完成 | 旧 release 不关闭后续新查询 |
| M5 | Right Option + Left Option，先松开 Right，再松开 Left | 最后一个相关修饰键松开后才提交 |
| M6 | 等待时 Esc / 关闭 / 点击窗外 | 取消；之后松键不粘贴、不重开 |
| M7 | 等待时切应用、来源退出、改快捷键或休眠 | 取消且无延迟提交 |
| M8 | 等待或执行中开始新查询 | 新查询正常；旧结果不更改新浮窗 |
| M9 | 多翻译源，一个完成后点击，另一个继续流式输出 | 仅提交所点击的完整译文；替换隐藏期间无重显 |
| M10 | 来源只读、选区已折叠、换窗口或换输入框 | 0 次粘贴，显示对应失败说明 |
| M11 | 目标实际替换，但 AX 结果不可读 | `.pasteDispatched`，浮窗关闭，不误报成功、不重发 |
| M12 | 测试编辑器故意忽略 paste | 只收到一次事件；未确认、不自动重试，译文仍留在剪贴板 |
| M13 | 模拟延迟读取剪贴板 | 超时前后不会读取到被提前恢复的旧内容 |
| M14 | 替换过程中发生外部复制 | 用户新剪贴板内容不被覆盖 |
| M15 | 普通长按不点击替换后松开 | 原有关闭行为不变 |
| M16 | 短按、双击、双击后长按、固定结果、OCR | 原有展示与关闭策略不受影响 |
| M17 | 替换后在来源应用执行一次 ⌘Z | 可按来源编辑器的正常撤销粒度恢复 |
| M18 | App Store 版 | 无替换入口，也不进入新增等待或发送路径 |

**Step 2:** 至少在一个实际原生编辑器重复 M1–M3、M9、M17。浏览器只有在可稳定获取原始可编辑 AX 目标时才进行对应验收；失败按应用和阶段记录，不能扩展为通用兼容结论。

**Step 3:** 保存测试命令、执行项数、构建结果、实测应用版本和日志路径，列出无法验证的项目。没有真实覆盖的场景标为“未验证”，不写“通过”。

**Checkpoint:** 所有核心长按场景通过；未验证应用与环境有明确边界；产出可审查 diff 和 QA 记录。本计划结束不包含 commit、push 或发布。

## 13. 验证命令

以下命令从仓库根目录执行。日志和 DerivedData 使用本环境批准的任务临时目录；Task 0 将命令 A 的日志名改为 `held-replacement-regression-baseline.log`，Task 7 使用下列最终日志名，保留前后证据。使用结果包时选择新的 `-resultBundlePath`，不删除他人产物。命令中的检查结果是预期，不代表本次编写计划时已运行。

### A. 相关回归

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-tests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementTests' \
  '-only-testing:SnapTra TranslatorTests/HotkeyManagerTests' \
  '-only-testing:SnapTra TranslatorTests/ParagraphOverlayLayoutTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextLookupRoutingTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextProbePolicyTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextProbeExecutorTests' \
  '-only-testing:SnapTra TranslatorTests/SinglePressLookupCoordinatorTests' \
  '-only-testing:SnapTra TranslatorTests/SinglePressLookupRequestTests' \
  test CODE_SIGNING_ALLOWED=NO \
  > '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-regression.log' 2>&1
```

预期：`TEST SUCCEEDED`，所选测试实际执行且 0 失败。Task 0 记录基线；Task 7 记录改动后的结果。

### B. 新功能与热键定向测试

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-tests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementCoordinatorTests' \
  '-only-testing:SnapTra TranslatorTests/SelectedTextReplacementTests' \
  '-only-testing:SnapTra TranslatorTests/HotkeyManagerTests' \
  test CODE_SIGNING_ALLOWED=NO \
  > '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-focused.log' 2>&1
```

预期：新增测试先因缺失行为失败，实现后全部通过；测试日志中必须出现新测试类。

### C. Direct Debug

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator Direct" -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-direct-debug' \
  build CODE_SIGNING_ALLOWED=NO \
  > '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-direct-debug.log' 2>&1
```

预期：`BUILD SUCCEEDED`。自动构建可禁签；需要 TCC 权限的实测使用可运行、已授权的最新 Direct Debug 构建，必要时按本机已有开发签名配置另行构建，不能把无签名产物的权限异常当作功能结论。

### D. Direct Release

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator Direct" -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-direct-release' \
  build CODE_SIGNING_ALLOWED=NO \
  > '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-direct-release.log' 2>&1
```

### E. App Store Release

```bash
xcodebuild -project "SnapTra Translator.xcodeproj" \
  -scheme "SnapTra Translator" -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-appstore-release' \
  build CODE_SIGNING_ALLOWED=NO \
  > '/private/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/opencode/held-replacement-appstore-release.log' 2>&1
```

D、E 均预期 `BUILD SUCCEEDED`。可并行执行独立渠道构建，但不要让两个 xcodebuild 同时写同一 DerivedData。

### F. 文件检查

```bash
git diff --check
```

```bash
python3 -m json.tool 'SnapTra Translator/Localizable.xcstrings' > /dev/null
```

```bash
plutil -lint 'SnapTra Translator.xcodeproj/project.pbxproj'
```

预期：退出码均为 0。

## 14. 完成标准

- 长按点击后继续按住超过 500ms 仍可在松键后完成替换；等待时无窗口闪回或剪贴板占用。
- 松键不取消替换，旧关闭动作和旧完成回调不影响后续查询。
- 相同请求仅发送一对 V down / up；发送后立即标记消费，不自动重试。
- 替换执行中其他翻译结果无法重开窗口；已发送的两种结果均结束当前浮窗。
- 发送前失败可见且可恢复，实际目标仍按进程、窗口、控件、选区和原文严格复核。
- 未确认结果保留译文，外部剪贴板更新不被覆盖。
- 常驻替换、普通长按关闭、双击 OCR、短按保留、Esc、固定面板与 App Store 限制均通过相应回归。
- 新增行为测试、双渠道构建和 QA 记录齐全，未验证内容明确列出。
