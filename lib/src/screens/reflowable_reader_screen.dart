import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/ebook.dart';
import '../services/reading_progress_store.dart';

class ReflowableReaderScreen extends StatefulWidget {
  const ReflowableReaderScreen({
    super.key,
    required this.book,
    required this.content,
  });

  final Ebook book;
  final ReflowableBook content;

  @override
  State<ReflowableReaderScreen> createState() => _ReflowableReaderScreenState();
}

class _ReflowableReaderScreenState extends State<ReflowableReaderScreen> {
  late final PageController _pageController;
  late final List<String> _chapterTexts;
  Future<ReadingProgressStore>? _progressStore;
  Future<void> _saveQueue = Future<void>.value();

  List<_ReaderPage> _pages = const [];
  String? _paginationKey;
  double? _readingViewportHeight;
  int _currentPage = 0;
  int _currentChapter = 0;
  int _currentOffset = 0;
  int _restoredChapter = 0;
  int _restoredOffset = 0;
  bool _restoreReady = false;
  bool _restoreApplied = false;
  bool _progressRestored = false;
  bool _jumpScheduled = false;
  int _scheduledPage = 0;
  bool _scheduledJumpCompletesRestore = false;
  double _fontSize = 17;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _chapterTexts = widget.content.chapters.map(_plainText).toList();
    _restoreProgress();
  }

  Future<void> _restoreProgress() async {
    final store = await _store();
    final chapter = store
        .reflowableChapter(widget.book.type, widget.book.fileName)
        .clamp(0, widget.content.chapters.length - 1);
    final offset = store.reflowableOffset(
      widget.book.type,
      widget.book.fileName,
    );
    if (!mounted) return;
    setState(() {
      _restoredChapter = chapter;
      _restoredOffset = math.max(0, offset);
      _fontSize = store.reflowableFontSize.clamp(12, 34);
      _restoreReady = true;
      _paginationKey = null;
    });
  }

  Future<ReadingProgressStore> _store() async {
    return _progressStore ??= ReadingProgressStore.create();
  }

  Future<void> _writeProgress(
    int chapter,
    int offset,
    int totalChapters,
    double fontSize,
  ) async {
    final store = await _store();
    await store.saveReflowable(
      type: widget.book.type,
      fileName: widget.book.fileName,
      chapter: chapter,
      offset: offset,
      totalChapters: totalChapters,
      fontSize: fontSize,
    );
  }

  void _queueProgressSave() {
    if (!_progressRestored) return;
    final chapter = _currentChapter;
    final offset = _currentOffset;
    final totalChapters = widget.content.chapters.length;
    final fontSize = _fontSize;
    _saveQueue = _saveQueue
        .then((_) => _writeProgress(chapter, offset, totalChapters, fontSize))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('保存电子书阅读进度失败：$error');
        });
  }

  @override
  void dispose() {
    _queueProgressSave();
    _pageController.dispose();
    super.dispose();
  }

  void _goToChapter(int chapter) {
    if (chapter < 0 || chapter >= widget.content.chapters.length) return;
    final page = _pages.indexWhere((item) => item.chapterIndex == chapter);
    if (page >= 0) _goToPage(page);
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _pages.length) return;
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  void _changeFontSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(12, 34);
      _paginationKey = null;
    });
    _queueProgressSave();
  }

  Future<void> _showChapterList() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '目录',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: widget.content.chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = widget.content.chapters[index];
                    final selected = index == _currentChapter;
                    return ListTile(
                      selected: selected,
                      leading: Icon(
                        selected
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                      ),
                      title: Text(
                        chapter.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, index),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) _goToChapter(selected);
  }

  String _plainText(ReflowableChapter chapter) {
    final document = html_parser.parse(chapter.html);
    final body = document.body;
    final heading = body?.querySelector('h1, h2, h3');
    if (heading != null &&
        _normalizedText(heading.text) == _normalizedText(chapter.title)) {
      heading.remove();
    }
    final withBreaks = (body?.innerHtml ?? chapter.html)
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(
            r'</(?:p|div|li|blockquote|h[1-6]|section|article)>',
            caseSensitive: false,
          ),
          '\n\n',
        );
    final text = html_parser.parseFragment(withBreaks).text ?? '';
    return text
        .replaceAll('\uFEFF', '')
        .replaceAll('\u00AD', '')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  String _normalizedText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<_ReaderPage> _pagesFor(
    BuildContext context,
    BoxConstraints constraints,
    TextStyle titleStyle,
    TextStyle bodyStyle,
  ) {
    if (_showControls || _readingViewportHeight == null) {
      _readingViewportHeight = constraints.maxHeight;
    }
    final viewport = Size(
      constraints.maxWidth,
      math.min(constraints.maxHeight, _readingViewportHeight!),
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final key = [
      viewport.width.toStringAsFixed(1),
      viewport.height.toStringAsFixed(1),
      _fontSize.toStringAsFixed(1),
      textScaler.scale(1).toStringAsFixed(3),
      textDirection.name,
    ].join(':');
    if (_paginationKey == key) return _pages;

    final previousChapter = _currentChapter;
    final previousOffset = _currentOffset;
    _pages = _paginate(
      viewport,
      titleStyle: titleStyle,
      bodyStyle: bodyStyle,
      textScaler: textScaler,
      textDirection: textDirection,
    );
    _paginationKey = key;

    final completingRestore = _restoreReady && !_restoreApplied;
    final targetChapter = completingRestore
        ? _restoredChapter
        : previousChapter;
    final targetOffset = completingRestore ? _restoredOffset : previousOffset;
    final targetPage = _findPage(targetChapter, targetOffset);
    _currentPage = targetPage;
    if (_pages.isNotEmpty) {
      _currentChapter = _pages[targetPage].chapterIndex;
      _currentOffset = _pages[targetPage].startOffset;
    }
    if (completingRestore) _restoreApplied = true;
    _schedulePageJump(targetPage, completesRestore: completingRestore);
    return _pages;
  }

  List<_ReaderPage> _paginate(
    Size viewport, {
    required TextStyle titleStyle,
    required TextStyle bodyStyle,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    final contentWidth = math.max(80.0, math.min(760.0, viewport.width - 48));
    final contentHeight = math.max(80.0, viewport.height - 56);
    final pages = <_ReaderPage>[];

    for (
      var chapterIndex = 0;
      chapterIndex < widget.content.chapters.length;
      chapterIndex++
    ) {
      final chapter = widget.content.chapters[chapterIndex];
      final text = _chapterTexts[chapterIndex];
      final titlePainter = TextPainter(
        text: TextSpan(text: chapter.title, style: titleStyle),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout(maxWidth: contentWidth);
      final bodyPainter = TextPainter(
        text: TextSpan(text: text, style: bodyStyle),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout(maxWidth: contentWidth);

      if (text.isEmpty) {
        pages.add(
          _ReaderPage(
            chapterIndex: chapterIndex,
            pageInChapter: 0,
            startOffset: 0,
            endOffset: 0,
            text: '',
            showsTitle: true,
          ),
        );
        continue;
      }

      final firstPageHeight = math.max(
        bodyPainter.preferredLineHeight,
        contentHeight - titlePainter.height - 24,
      );
      var start = 0;
      var consumedHeight = 0.0;
      var pageInChapter = 0;
      while (start < text.length) {
        final availableHeight = pageInChapter == 0
            ? firstPageHeight
            : contentHeight;
        final targetHeight = consumedHeight + availableHeight;
        var end = text.length;
        if (targetHeight < bodyPainter.height) {
          final probeHeight = math.max(consumedHeight, targetHeight - 0.5);
          end = bodyPainter.getPositionForOffset(Offset(0, probeHeight)).offset;
          if (end <= start) {
            end = bodyPainter
                .getPositionForOffset(Offset(contentWidth, probeHeight))
                .offset;
          }
          if (end <= start) end = math.min(text.length, start + 1);
        }
        end = _fitPageEnd(
          text,
          start: start,
          candidateEnd: end,
          maxHeight: availableHeight,
          width: contentWidth,
          style: bodyStyle,
          textScaler: textScaler,
          textDirection: textDirection,
        );

        pages.add(
          _ReaderPage(
            chapterIndex: chapterIndex,
            pageInChapter: pageInChapter,
            startOffset: start,
            endOffset: end,
            text: text.substring(start, end).trim(),
            showsTitle: pageInChapter == 0,
          ),
        );
        start = end;
        pageInChapter++;
        if (start < text.length) {
          consumedHeight = bodyPainter
              .getOffsetForCaret(TextPosition(offset: start), Rect.zero)
              .dy;
        }
      }
    }
    return pages;
  }

  int _fitPageEnd(
    String text, {
    required int start,
    required int candidateEnd,
    required double maxHeight,
    required double width,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    var end = candidateEnd;
    while (end > start) {
      final fragment = text.substring(start, end).trimRight();
      final painter = TextPainter(
        text: TextSpan(text: fragment, style: style),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout(maxWidth: width);
      if (painter.height <= maxHeight + 0.1) return end;

      final probeHeight = math.max(0.0, maxHeight - 0.5);
      var localEnd = painter
          .getPositionForOffset(Offset(0, probeHeight))
          .offset;
      if (localEnd <= 0) {
        localEnd = painter
            .getPositionForOffset(Offset(width, probeHeight))
            .offset;
      }
      final reducedEnd = start + (localEnd < 1 ? 1 : localEnd);
      end = reducedEnd < end ? reducedEnd : end - 1;
    }
    return start + 1 < text.length ? start + 1 : text.length;
  }

  int _findPage(int chapter, int offset) {
    if (_pages.isEmpty) return 0;
    var result = _pages.indexWhere((page) => page.chapterIndex == chapter);
    if (result < 0) return 0;
    for (var index = result; index < _pages.length; index++) {
      final page = _pages[index];
      if (page.chapterIndex != chapter || page.startOffset > offset) break;
      result = index;
    }
    return result;
  }

  void _schedulePageJump(int page, {required bool completesRestore}) {
    _scheduledPage = page;
    _scheduledJumpCompletesRestore |= completesRestore;
    if (_jumpScheduled) return;
    _jumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpScheduled = false;
      if (!mounted) return;
      if (!_pageController.hasClients) {
        _schedulePageJump(
          _scheduledPage,
          completesRestore: _scheduledJumpCompletesRestore,
        );
        return;
      }
      final maxPage = _pages.isEmpty ? 0 : _pages.length - 1;
      final target = _scheduledPage < 0
          ? 0
          : _scheduledPage > maxPage
          ? maxPage
          : _scheduledPage;
      _pageController.jumpToPage(target);
      if (_scheduledJumpCompletesRestore) {
        _scheduledJumpCompletesRestore = false;
        _progressRestored = true;
        _queueProgressSave();
      }
      setState(() {});
    });
  }

  void _handlePageChanged(int page) {
    if (page < 0 || page >= _pages.length) return;
    final readerPage = _pages[page];
    setState(() {
      _currentPage = page;
      _currentChapter = readerPage.chapterIndex;
      _currentOffset = readerPage.startOffset;
    });
    _queueProgressSave();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final titleStyle = (theme.textTheme.titleLarge ?? const TextStyle())
        .copyWith(
          fontSize: _fontSize + 6,
          height: 1.35,
          fontWeight: FontWeight.w700,
        );
    final bodyStyle = (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: _fontSize,
      height: 1.8,
    );
    return Scaffold(
      appBar: _showControls
          ? AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.content.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    widget.content.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: [
                IconButton(
                  onPressed: _showChapterList,
                  tooltip: '目录',
                  icon: const Icon(Icons.format_list_bulleted_rounded),
                ),
              ],
            )
          : null,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => _showControls = !_showControls),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pages = _pagesFor(
              context,
              constraints,
              titleStyle,
              bodyStyle,
            );
            return PageView.builder(
              controller: _pageController,
              itemCount: pages.length,
              onPageChanged: _handlePageChanged,
              itemBuilder: (context, index) {
                final page = pages[index];
                final chapter = widget.content.chapters[page.chapterIndex];
                return SelectionArea(
                  key: ValueKey(
                    '${widget.book.type.name}-${widget.book.fileName}-${page.chapterIndex}-${page.startOffset}',
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (page.showsTitle) ...[
                              Text(chapter.title, style: titleStyle),
                              const SizedBox(height: 24),
                            ],
                            Text(page.text, style: bodyStyle),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      bottomNavigationBar: _showControls
          ? Material(
              color: colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            _pages.isEmpty
                                ? '正在分页…'
                                : '${_currentPage + 1} / ${_pages.length} 页',
                            key: const Key('reader-page-indicator'),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: _pages.isEmpty
                                  ? null
                                  : (_currentPage + 1) / _pages.length,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          IconButton(
                            onPressed: _fontSize > 12
                                ? () => _changeFontSize(-1)
                                : null,
                            tooltip: '减小字号',
                            icon: const Icon(Icons.text_decrease_rounded),
                          ),
                          SizedBox(
                            width: 32,
                            child: Text(
                              _fontSize.round().toString(),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          IconButton(
                            onPressed: _fontSize < 34
                                ? () => _changeFontSize(1)
                                : null,
                            tooltip: '增大字号',
                            icon: const Icon(Icons.text_increase_rounded),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: _currentPage > 0
                                ? () => _goToPage(_currentPage - 1)
                                : null,
                            tooltip: '上一页',
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                          IconButton(
                            onPressed: _currentPage < _pages.length - 1
                                ? () => _goToPage(_currentPage + 1)
                                : null,
                            tooltip: '下一页',
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

class _ReaderPage {
  const _ReaderPage({
    required this.chapterIndex,
    required this.pageInChapter,
    required this.startOffset,
    required this.endOffset,
    required this.text,
    required this.showsTitle,
  });

  final int chapterIndex;
  final int pageInChapter;
  final int startOffset;
  final int endOffset;
  final String text;
  final bool showsTitle;
}
