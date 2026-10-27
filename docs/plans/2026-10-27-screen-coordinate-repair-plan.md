# Selected Text Screen Coordinates Implementation Plan

**Goal:** 外屏插拔、重排、切换主屏及缩放后，选区命中仍使用正确坐标；已绑定的替换目标通过原控件与原选区继续验证。

**Architecture:** 每次查询捕获不可变的屏幕配置和 AX 鼠标位置。AX 命中与选区几何判断统一使用 Quartz 全局逻辑坐标，AppKit 只在界面边界转换。屏幕变化时丢弃过期探测，保留已经建立的选中文本翻译及替换身份；提交仍严格复核进程、窗口、控件、范围和原文。

**Tech Stack:** Swift、AppKit、ApplicationServices、CoreGraphics、XCTest；不增加依赖，不提交或推送。

## 1. 屏幕配置与坐标

- 修改 `SnapTra Translator/SelectedTextProbeExecutor.swift`，增加屏幕配置值类型，捕获每屏 display ID、AppKit frame 和 scale；原点取 `NSScreen.screens.first`，禁止使用所有屏幕的最大 `maxY` 或 `NSScreen.main`。
- 查询保存屏幕配置及转换后的 AX 点；AX 矩形在 AX 层直接与 AX 点比较，只在生成 UI 快照时转回 AppKit。
- 修改 `SnapTra TranslatorTests/SelectedTextPerformanceTests.swift`，验证外屏上下左右、负坐标、主屏变化、混合缩放、查询快照不随后续配置变化，以及旧配置结果不可采用。

## 2. 网页编辑器

- 修改 `SnapTra Translator/SelectedTextService.swift`，验证候选与焦点编辑器的双向祖先关系。祖先容器的范围不能当作编辑器内范围；绑定并保存焦点编辑器自己的范围与原文。
- 保留进程、窗口、明确可写、非安全字段和全部可读文本一致性门控。外层网页只读选区或其他输入框的同文选区不能获得替换资格。
- 在 `SnapTra TranslatorTests/SelectedTextReplacementTests.swift` 增加必要边界回归，并用真实浏览器控件确认。

## 3. 屏幕变化生命周期

- 修改 `SnapTra Translator/AppModel.swift`：探测前后比较屏幕配置，变化时丢弃结果、释放未采用的上下文，禁止回退到旧坐标 OCR 或复制。
- 屏幕变化后对还未建立目标的查询重新捕获配置；仅在原应用仍有效时重试。
- 已进入选中文本翻译的会话保留译文、任务和控件身份，重新定位浮窗；正在执行的粘贴取消，后续点击仍重新验证原目标。
- 保持 OCR 区域在显示器变化时失效的现有规则。

## 4. 验证

执行选区、替换、路由相关 XCTest，Direct Debug 及双渠道 Release 构建、`git diff --check`。真实 AX 验证使用同一鼠标位置，分别检查浏览器容器和 Telegram 的范围。应用间输入只用于独立测试文本；不发送聊天消息。

物理插拔、旋转及缩放通过合成屏幕布局测试覆盖坐标逻辑；未实际执行的硬件操作单独说明。微信缺少可验证 AX 目标时继续拒绝，不能退化为任意插入点粘贴。

## 实施结果

后续交互修订：按钮改为在 Direct 完整选中文本译文上稳定显示，替换捕获不再要求鼠标命中选区或编辑器几何范围；点击后校验原目标和可写性。下列关于几何绑定的描述保留为本次坐标修复的历史记录，当前规则见 `2026-10-27-selected-text-replacement-plan.md` 顶部修订。

- 已实现主屏原点转换、每次请求的 AX 点和屏幕配置快照，配置包含 display ID、frame、scale、rotation 及变化版本。
- AX 命中和选区范围判断直接使用 Quartz 坐标；屏幕配置过期时停止当前路由，取消结果同时释放未采用的替换上下文。
- 已修复网页容器包含焦点输入框时的绑定，要求鼠标位于该输入框范围内，并验证原文、窗口和可写性。
- 已建立的选中文本翻译在屏幕变化后保留译文和目标身份，重新定位浮窗；提交前仍检查原控件和原选区。未建立目标且来源仍有效时重新探测。
- 坐标修复阶段使用独立 DerivedData 目录执行 48 项相关测试，全部通过；后续稳定按钮版本删除旧的几何门控用例，实际执行 47 项，全部通过。最新 Direct Debug、Direct Release 及 App Store Release 构建均通过，字符串目录及差异检查通过。覆盖多屏位置、缩放、旋转及重连配置识别，旧配置拒绝、路由中途变化和取消结果清理。
- 坐标修复阶段的真实 UI 验证曾因锁屏受阻。后续已解除锁屏，并用最新 Direct 构建通过独立原生窗口的替换及失败路径验证；浏览器完整写回未通过，不能宣称真实网页或 Telegram 已端到端兼容。详细记录见 `../qa/2026-10-27-selected-text-replacement.md`。物理插拔及显示模式切换仍未执行。
