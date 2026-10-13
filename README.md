# Fluenca Reader

Fluenca Reader 是从 Fluenca 主应用拆分出来的独立 Flutter 电子书阅读器。项目不依赖 `fluenca` 或 `fluenca_db`，可以单独构建和运行。

## 功能

- 从设备多选导入 EPUB、PDF、MOBI 文件
- 独立书架与应用内文件存储
- EPUB 元数据、章节顺序和目录解析
- EPUB 3 navigation document 与 EPUB 2 NCX 目录支持
- EPUB 后台 isolate 解析及压缩包资源限制
- EPUB 章节翻页、文本选择、字号调整和阅读进度保存
- 无 DRM MOBI 6/7 元数据、PalmDOC 文本解压、pagebreak/filepos 章节阅读
- PDF 文本选择、缩放、页码跳转和阅读进度保存
- 删除书籍、下拉刷新、深色模式
- Android、iOS、macOS、Windows、Linux 工程配置

与语言学习数据相关的词汇、句子和长难句收藏没有迁入本项目；这些能力属于 Fluenca 主应用，而不是独立阅读器的核心依赖。

## 开发

项目的 Dart SDK 下限与 Fluenca 主项目保持为 `3.8.1`。

```bash
flutter pub get
flutter run
```

质量检查：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

## 文件存储

导入的文件会复制到应用 Documents 目录下的 `ebooks` 文件夹。重名文件会以 `书名 (2).epub` 这样的形式保留副本。阅读进度通过 `shared_preferences` 保存在设备本地。

默认拒绝超过 200 MB 的 EPUB 或 MOBI 文件。EPUB 解压后内容上限为 512 MB，压缩包最多包含 10,000 个条目；MOBI 解压后的文本上限为 100 MB，最多包含 10,000 条记录和 2,000 个章节。超过限制时会明确报错，不会截断正文。

MOBI 当前支持无压缩及 PalmDOC LZ77 压缩的无 DRM Mobipocket 6/7 文件；暂不支持带 DRM 的文件、Huff/CDIC 压缩和 Kindle KF8 专有排版。

## PDF 组件

PDF 阅读使用 Syncfusion Flutter PDF Viewer。发布应用前，请确认所使用的 Syncfusion Community License 或商业许可证满足发布条件。
