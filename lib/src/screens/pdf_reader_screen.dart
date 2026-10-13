import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../models/ebook.dart';
import '../services/reading_progress_store.dart';

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key, required this.book});

  final Ebook book;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final PdfViewerController _controller = PdfViewerController();
  Future<ReadingProgressStore>? _progressStore;
  Future<void> _saveQueue = Future<void>.value();
  int _currentPage = 1;
  int _totalPages = 0;
  int? _pendingRestoredPage;
  bool _progressRestored = false;
  double _zoom = 1;

  Future<ReadingProgressStore> _store() async {
    return _progressStore ??= ReadingProgressStore.create();
  }

  Future<void> _handleDocumentLoaded(int totalPages) async {
    if (!mounted) return;
    setState(() => _totalPages = totalPages);

    final store = await _store();
    final page = store.pdfPage(widget.book.fileName).clamp(1, _totalPages);
    await store.savePdfTotalPages(
      fileName: widget.book.fileName,
      totalPages: totalPages,
    );
    if (!mounted) return;

    setState(() => _currentPage = page);
    if (page > 1) {
      _pendingRestoredPage = page;
      _controller.jumpToPage(page);
    } else {
      _progressRestored = true;
    }
  }

  Future<void> _writeProgress(int page, int totalPages) async {
    final store = await _store();
    await store.savePdf(
      fileName: widget.book.fileName,
      page: page,
      totalPages: totalPages,
    );
  }

  void _queueProgressSave() {
    if (!_progressRestored) return;
    final page = _currentPage;
    final totalPages = _totalPages;
    _saveQueue = _saveQueue
        .then((_) => _writeProgress(page, totalPages))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('保存 PDF 阅读进度失败：$error');
        });
  }

  void _changeZoom(double delta) {
    setState(() {
      _zoom = (_zoom + delta).clamp(0.75, 3);
      _controller.zoomLevel = _zoom;
    });
  }

  Future<void> _showPagePicker() async {
    final textController = TextEditingController(text: '$_currentPage');
    final page = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转到页面'),
        content: TextField(
          controller: textController,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: '页码',
            helperText: '范围：1–$_totalPages',
          ),
          onSubmitted: (value) {
            final parsed = int.tryParse(value);
            if (parsed != null) Navigator.pop(context, parsed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(textController.text)),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (page != null && page >= 1 && page <= _totalPages) {
      _controller.jumpToPage(page);
    }
  }

  @override
  void dispose() {
    _queueProgressSave();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (_totalPages > 0)
              Text(
                '第 $_currentPage / $_totalPages 页',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _zoom > 0.75 ? () => _changeZoom(-0.25) : null,
            tooltip: '缩小',
            icon: const Icon(Icons.zoom_out_rounded),
          ),
          IconButton(
            onPressed: _zoom < 3 ? () => _changeZoom(0.25) : null,
            tooltip: '放大',
            icon: const Icon(Icons.zoom_in_rounded),
          ),
          if (_totalPages > 0)
            IconButton(
              onPressed: _showPagePicker,
              tooltip: '跳转页面',
              icon: const Icon(Icons.find_in_page_outlined),
            ),
        ],
      ),
      body: SfPdfViewer.file(
        widget.book.file,
        controller: _controller,
        canShowScrollHead: true,
        canShowScrollStatus: true,
        enableTextSelection: true,
        onDocumentLoaded: (details) {
          _handleDocumentLoaded(details.document.pages.count);
        },
        onDocumentLoadFailed: (details) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('PDF 加载失败：${details.description}')),
          );
        },
        onPageChanged: (details) {
          setState(() => _currentPage = details.newPageNumber);
          if (_pendingRestoredPage case final restoredPage?) {
            if (details.newPageNumber == restoredPage) {
              _pendingRestoredPage = null;
              _progressRestored = true;
              _queueProgressSave();
            }
            return;
          }
          _queueProgressSave();
        },
      ),
      bottomNavigationBar: _totalPages == 0
          ? null
          : Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _currentPage > 1
                            ? _controller.previousPage
                            : null,
                        tooltip: '上一页',
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Expanded(
                        child: Text(
                          '$_currentPage / $_totalPages',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        onPressed: _currentPage < _totalPages
                            ? _controller.nextPage
                            : null,
                        tooltip: '下一页',
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
