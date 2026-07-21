# Markdown 写作体验 M1 验收清单

这份清单用于验证 Markdown Card 的第一轮写作体验优化。建议新建标题含 `QA M1` 的临时卡进行测试，完成后删除，避免影响正式内容。

## 自动化回归

在项目根目录执行：

```bash
cd /path/to/markdown-card
(cd Renderer && npm run check)
swift test --disable-sandbox
./Scripts/integration_test.sh
codesign --verify --deep --strict --verbose=2 "dist/Markdown Card.app"
git diff --check
```

全部命令应以退出码 `0` 完成。若 `swift test` 在受限终端中提示 module cache 或 Unix socket 权限错误，应换到普通 Terminal 重跑；这类错误不代表产品逻辑失败。

## 核心手测

| ID | 场景 | 操作 | 期望结果 |
| --- | --- | --- | --- |
| M1-01 | 空卡引导 | 新建空卡，不输入内容 | 看到克制的 Markdown/命令提示；开始输入后提示消失，正文不包含提示文字 |
| M1-02 | 链接创建 | 输入并选中“官方文档”，按 `⌘K`，填写 `https://example.com/docs` 后按 Return | 不离开键盘即可建立链接；Copy 后得到 `[官方文档](https://example.com/docs)` |
| M1-03 | 链接编辑与移除 | 把光标放进上一步链接，按 `⌘K`；修改标签和 URL；再次打开并选择移除 | 面板预填现有值；修改后选区保持合理；移除只去掉链接，不删除标签文本 |
| M1-04 | 快捷键隔离 | 在正文按 `⌘K`，再按 `⌘⇧L` | 前者只打开链接面板；后者只打开 Card Library；两者不抢占 |
| M1-05 | `/table` 创建 | 在空段落输入 `/table`，用方向键选中 Table，按 Return | 插入 3×3、含表头的表格；命令字符不残留；光标进入首个单元格 |
| M1-06 | 窄卡宽表 | 在 Sticky 布局粘贴下方 6 列表格，横向滚动到最后一列 | 表格不被裁切，所有列可到达；卡片正文整体不横向漂移 |
| M1-07 | Full Screen 阅读与切换 | 粘贴 10–15 行普通正文，切到 Full Screen，再用 `⌘Tab` 切到其他 App 后切回 | 正文保持居中、行长舒适；Dock/App Switcher 出现 Markdown Card；其他 App 能盖住卡片；切回内容、焦点和布局不丢失 |
| M1-08 | 代码块退出 | 输入三个反引号加 `python` 并回车，输入两行代码，在末尾按 `⌘Return` | 在代码块后创建普通段落并把光标移入；代码内容和语言不变 |
| M1-09 | 代码语言提示 | 创建 `python`、`swift` 和无语言代码块 | 有语言时能看见克制的语言标识；无语言时不显示虚假语言 |
| M1-10 | 纯文本导出 | 新建无图片卡，输入两段文字，点击 Export，保存为 `.md` | Export 始终可见；生成单个 UTF-8 Markdown 文件，内容与 Copy 一致，不额外创建空附件目录 |
| M1-11 | 附件导出回归 | 粘贴一张截图后 Export | 仍生成 `.md` 与 `attachments/`；Markdown 使用相对附件路径，图片能随文件搬移 |
| M1-12 | Mini 键盘恢复 | 切到 Mini，开启 macOS Keyboard Navigation，不移动鼠标，用 Tab/Shift-Tab 找到 Layout 并激活 | Layout 可通过键盘发现和操作，焦点可见；鼠标未悬停也不会把控件彻底禁用 |
| M1-13 | Full Screen 身份恢复 | 从 Full Screen 切回 Sticky；再分别保持 Library、第二张 Full Screen 卡片打开后退出第一张 Full Screen | 普通卡重新悬浮并跨 Space；只有在没有 Full Screen、Library、Settings 时 Dock/App Switcher 图标才消失 |

## 输入与恢复回归

| ID | 场景 | 操作 | 期望结果 |
| --- | --- | --- | --- |
| R-01 | 中文输入法 | 用系统拼音连续输入 3 段中文，候选翻页并用 Return 确认 | 不丢字、不重复、不多出空行，候选确认不会误提交链接或 Slash 命令 |
| R-02 | 撤销 | 依次创建链接、表格、代码块，然后逐步按 `⌘Z`/`⌘⇧Z` | 每次撤销对应一个可理解的用户动作，无跨卡内容污染 |
| R-03 | 隐藏恢复 | 输入最后一句后立刻按 `⌘W`，再从 Command Center 打开 | 最后字符、表格、链接和代码语言完整恢复 |
| R-04 | Copy round-trip | Copy 整张 QA 卡并粘到纯文本编辑器 | Placeholder、链接面板 UI、代码语言标签不进入 Markdown；正文语义完整 |
| R-05 | 主题与动效 | 切换 Light/Dark/System，并开启 Reduce Motion | 焦点、占位符、表格滚动和链接面板都清楚；Reduce Motion 下没有必要的弹跳动画 |

## 6 列表格数据

```markdown
| Name | Type | Range | Default | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| temperature | float | 0–2 | 0.7 | active | Long-form metadata that should remain reachable in Sticky |
| top_p | float | 0–1 | 0.9 | active | Scroll horizontally to inspect this final cell |
```

## Full Screen 段落数据

```markdown
# Readable width

Markdown Card should feel like a focused sheet of paper in Full Screen, not like a line stretched from one side of the display to the other. A comfortable measure lets the eye return to the next line without losing its place.

Repeat this paragraph several times, then compare Sticky and Full Screen. Sticky should keep its compact rhythm. Full Screen should add breathing room around a centered reading column instead of enlarging every line indefinitely.
```

## 失败记录模板

```text
Test ID:
macOS version:
Layout and theme:
Input method:
Steps:
Expected:
Actual:
Screenshot or screen recording:
Reproducibility: always / intermittent / once
```
