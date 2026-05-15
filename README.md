# PDF Toolbox

一个基于 Swift 的命令行 PDF 批量处理工具，支持压缩、拆分、图片转换以及带 OCR 识别的 Word 导出。

## 功能特性

### 支持的操作

| 操作 | 说明 |
|------|------|
| **压缩** (1) | 使用系统 Quartz Filter 减小 PDF 文件体积，自动跳过已最优压缩的文件 |
| **拆分** (2) | 将多页 PDF 按页拆分为独立的单页 PDF 文件 |
| **转 JPEG** (3) | 将 PDF 每一页渲染为高画质 JPEG 图片（2x 缩放，85% 质量） |
| **转 Word** (4) | 将 PDF 转为 .docx 格式：优先提取原生文本，扫描件自动启用 OCR |
| **强制 OCR** (5) | 等同转 Word，但跳过原生文本提取直接使用 OCR |

### 核心特点

- **支持批量处理** — 可同时传入多个文件或文件夹，自动递归收集 PDF
- **并发处理** — 根据 CPU 核心数自动调整并发度（2-4 任务并行）
- **OCR 识别** — 集成 Apple Vision 框架，支持中英文（简体/繁体）混合识别
- **优雅取消** — 按 `Ctrl+C` 可安全中断正在进行的任务
- **交互模式** — 不传操作参数时自动进入菜单式交互界面
- **彩色输出** — 终端输出带颜色标记，结果汇总一目了然

## 环境要求

**Apple Silicon macOS** 12.0 (Monterey) 或更高版本（依赖 `Vision` 框架）

## 安装

```bash
brew install --formula dct74/pdf-toolbox
```

## 使用方法

### 命令行模式

```bash
# 压缩 PDF
./pdf-toolbox 1 document.pdf

# 拆分 PDF 为单页
./pdf-toolbox 2 document.pdf

# 转为 JPEG 图片
./pdf-toolbox 3 document.pdf

# 转为 Word（自动判断是否需要 OCR）
./pdf-toolbox 4 document.pdf

# 强制使用 OCR 转为 Word
./pdf-toolbox 5 document.pdf

# 批量处理多个文件或文件夹
./pdf-toolbox 1 file1.pdf /path/to/folder file2.pdf
```

### 选项

| 选项 | 说明 |
|------|------|
| `--force-ocr` | 强制使用 OCR 处理（等同于操作 5） |
| `--help, -h` | 显示帮助信息 |

#### 示例

```bash
# 强制 OCR 模式
./pdf-toolbox --force-ocr scanned_doc.pdf

# 查看帮助
./pdf-toolbox --help
```

### 交互模式

不指定操作编号时进入交互模式：

```bash
./pdf-toolbox document.pdf
```

显示菜单：

```
========================================
 🛠️ PDF Batch Tool
========================================
1. Reduce File Size
2. Split PDF
3. Convert to JPEG
4. Convert to Word (Text/OCR, no layout)
5. Convert to Word (Force OCR)
Q. Exit

Enter option (1-5, Q):
```

### 拖拽操作

在终端中直接拖拽文件或文件夹到脚本路径后执行：

```bash
./pdf-toolbox 1 /path/to/dropped/file.pdf
```

## 输出说明

- **压缩**：在原文件同目录生成 `文件名.reduced.pdf`
- **拆分**：在原文件同目录创建 `文件名/` 文件夹，内包含 `文件名_Page1.pdf`、`文件名_Page2.pdf` ...
- **转 JPEG**：在原文件同目录创建 `文件名/` 文件夹，内包含 `文件名_Page1.jpg`、`文件名_Page2.jpg` ...
- **转 Word**：在原文件同目录生成 `文件名.docx`

处理完成后会输出统计报告：

```
📊 Processing complete. Success: 3, Failed: 1, Cancelled: 2
```

## 技术栈

- [PDFKit](https://developer.apple.com/documentation/pdfkit) — PDF 文档读写
- [CoreGraphics / Quartz](https://developer.apple.com/documentation/coregraphics) — 页面渲染与压缩滤镜
- [Vision](https://developer.apple.com/documentation/vision) — 文本识别（OCR）
- [ImageIO](https://developer.apple.com/documentation/imageio) — JPEG 图片编码
- [textutil](https://ss64.com/osx/textutil.html) — 系统命令行工具，用于生成 .docx 文件

## 许可证

MIT License
