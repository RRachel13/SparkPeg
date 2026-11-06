<p align="center">
  <img src="Sources/Tendedero/Resources/SparkPeg.png" width="112" height="112" alt="SparkPeg app icon">
</p>

# SparkPeg

A clothesline for the things you want to keep in sight. Clip a screenshot, a passage, or a passing thought to the top of your Mac screen. Take it down when you're done.

<p align="center">
  <a href="https://github.com/RRachel13/SparkPeg/releases/download/v1.2.0/SparkPeg-1.2.0-macOS.zip">
    <img src="https://img.shields.io/badge/Download_for_macOS-6D5DE7?style=for-the-badge&amp;logo=apple&amp;logoColor=white" alt="Download for macOS · 下载 Mac 版">
  </a>
  <br>
  <sub>v1.2.0 · macOS 14+ · Apple silicon &amp; Intel</sub>
</p>

[English](#english) · [简体中文](#简体中文)

## English

### What you can do

- **Hang screenshots and images.** Capture with the usual macOS shortcuts. Use the menu bar to manage screenshot handling, watch image folders, or hang copied images.
- **Capture a thought.** Press **⌘E** to hang selected text. With no text selected, the same shortcut opens an editor for a new idea. Press **⌘⇧E** to select text directly on the screen using on-device text recognition.
- **Work with your cards.** Double-click a note to edit it and add a separate remark. Use the right-click menu to pin, hold, copy, or share cards. Scroll over the line to see older cards.
- **Read and write Markdown.** Text cards grow to fit the note up to a height limit. Hold a note to scroll through its full text and remark. Markdown formats as you type. Click a line to edit its source, then move away to see it formatted again.
- **Return to the source.** New text excerpts captured with **⌘E** in supported browsers or Codex can show **Locate original** when SparkPeg saves a source. For example, Safari can highlight the original passage, and Codex can reopen the conversation and search for the quote. **Ask GPT** opens the note in a Codex draft for you to review.
- **Archive or discard.** Archive moves the original file into the Archive Library. Open the library from the menu bar to browse files or choose its folder. Discard moves the original to the macOS Trash, where you can recover it.

### Install on macOS

Requires **macOS 14 Sonoma or later**. The release ZIP contains a universal build for Apple silicon and Intel Macs.

1. Download `SparkPeg-1.2.0-macOS.zip` from [Release v1.2.0](../../releases/tag/v1.2.0).
2. Unzip it, drag **SparkPeg.app** to **Applications**, and open it. Click the SparkPeg menu bar icon to get started. The default shortcut to show or hide the line is **⌃⌥T**.
3. This build is ad hoc signed and has no Apple notarization. If macOS blocks the first launch and you trust the download, use **System Settings → Privacy & Security → Open Anyway**. [Apple's instructions](https://support.apple.com/en-us/102445)
4. When prompted, allow **Accessibility** for selected-text capture and **Screen & System Audio Recording** for on-screen text recognition. Allow folder access if you want SparkPeg to watch that folder.

Notes and archived files are stored on your Mac. The Archive Library shows its active folder and lets you choose another. Selecting a different archive location opens that library and keeps earlier archives in their original folders.

### Build from source

Install Apple's Command Line Tools (`xcode-select --install`) or Xcode with a recent macOS SDK. Run these commands from the repository root:

```sh
bash scripts/build-local.sh
open build/SparkPeg.app
```

Set `SPARKPEG_ARCHS='arm64 x86_64'` when running the build script to build a universal app.

## 简体中文

SparkPeg 是一根挂在 Mac 屏幕上方的灵感晾衣绳。看到一句想留的话、截下一张图，或突然想到什么，都可以随手挂上去，用完再取下来。

### 主要功能

- **挂上截图和图片。** 沿用 macOS 截图快捷键。在菜单栏可以设置截图处理方式、监听图片文件夹，或自动挂上复制的图片。
- **摘录文字，随手记灵感。** 选中文字后按 **⌘E** 挂成便签。没有选中文字时，同一个快捷键会打开灵感编辑框。按 **⌘⇧E** 可以直接选择屏幕上的文字，识别在本机完成。
- **在挂绳上整理。** 双击便签可编辑正文和单独的备注。右键可以固定、拿在手上、复制或分享卡片。鼠标停在挂绳上滚动，可以翻到较早的卡片。
- **读写 Markdown。** 文字便签会随内容增高，超过高度上限才省略。选择「拿在手上」可滚动阅读完整正文和备注。Markdown 会实时排版。点击一行即可编辑原文，光标移开后自动恢复排版。
- **定位到原文。** 用 **⌘E** 从受支持的浏览器或 Codex 摘录文字时，如果成功保存来源，就会出现「定位到原文」。例如，Safari 可以高亮原文，Codex 可以回到原会话并查找摘录。「询问 GPT」会把便签内容填进 Codex 草稿。
- **归档或丢弃。** 「归档」把原文件移入档案库，可从菜单栏打开查看和设置位置。「丢弃」把原文件移入 macOS 废纸篓，可以从那里找回。

### 在 macOS 上安装

需要 **macOS 14 Sonoma 或更高版本**。发布压缩包包含同时支持 Apple 芯片和 Intel Mac 的通用版本。

1. 从 [v1.2.0 发布页](../../releases/tag/v1.2.0) 下载 `SparkPeg-1.2.0-macOS.zip`。
2. 解压后，把 **SparkPeg.app** 拖进「应用程序」并打开。点击菜单栏上的 SparkPeg 图标即可开始使用。显示或隐藏挂绳的默认快捷键为 **⌃⌥T**。
3. 发布包采用临时签名，未经 Apple 公证。如果首次启动被 macOS 拦截，且你信任下载来源，可在「系统设置 → 隐私与安全性」选择「仍要打开」。 [Apple 官方说明](https://support.apple.com/zh-cn/102445)
4. 根据功能需要，在系统提示时允许权限。「辅助功能」用于直接摘录选中文字，「屏幕与系统音频录制」用于识别屏幕上的文字。监听特定文件夹时，按需允许该目录的访问。

便签和档案保存在本机。档案库窗口会显示当前存放位置，也可以在这里更换位置。切换后会打开所选位置的档案库，原有档案仍在原目录。

### 从源码构建

安装 Apple 命令行工具（`xcode-select --install`）或带有较新 macOS SDK 的 Xcode，在仓库根目录运行：

```sh
bash scripts/build-local.sh
open build/SparkPeg.app
```

构建时设置 `SPARKPEG_ARCHS='arm64 x86_64'` 可生成通用版本。

## Credits / 致谢

SparkPeg is based on Alejandro Buján’s [Tendedero](https://github.com/alejandrobujan/tendedero). The upstream source copyright and MIT terms are in [LICENSE](LICENSE).

SparkPeg 基于 Alejandro Buján 的 [Tendedero](https://github.com/alejandrobujan/tendedero) 开发。原始源码的版权及 MIT 条款见 [LICENSE](LICENSE)。
