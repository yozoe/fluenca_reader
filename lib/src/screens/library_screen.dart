import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/ebook.dart';
import '../services/ebook_library_service.dart';
import '../services/epub_service.dart';
import '../services/mobi_service.dart';
import '../services/reading_progress_store.dart';
import 'pdf_reader_screen.dart';
import 'reflowable_reader_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.libraryService});

  final EbookLibraryService? libraryService;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final EbookLibraryService _libraryService;
  ReadingProgressStore? _progressStore;
  List<Ebook> _books = const [];
  Map<String, String> _progressLabels = const {};
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _libraryService = widget.libraryService ?? EbookLibraryService();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    if (mounted) setState(() => _loading = true);
    try {
      final store = _progressStore ?? await ReadingProgressStore.create();
      final books = await _libraryService.loadBooks();
      final labels = <String, String>{};
      for (final book in books) {
        final label = _progressLabel(book, store);
        if (label != null) labels[book.file.path] = label;
      }
      if (!mounted) return;
      setState(() {
        _progressStore = store;
        _books = books;
        _progressLabels = labels;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('书架加载失败：$error', isError: true);
    }
  }

  String? _progressLabel(Ebook book, ReadingProgressStore store) {
    if (book.type != EbookType.pdf) {
      final chapter = store.reflowableChapter(book.type, book.fileName);
      final total = store.reflowableTotalChapters(book.type, book.fileName);
      if (total != null && total > 0) return '${chapter + 1} / $total 章';
      if (chapter > 0) return '第 ${chapter + 1} 章';
      return null;
    }

    final page = store.pdfPage(book.fileName);
    final total = store.pdfTotalPages(book.fileName);
    if (total != null && total > 0) return '$page / $total 页';
    if (page > 1) return '第 $page 页';
    return null;
  }

  Future<void> _importBooks() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择电子书',
        type: FileType.custom,
        allowedExtensions: const ['epub', 'pdf', 'mobi'],
        allowMultiple: true,
      );
      if (result == null) return;

      var imported = 0;
      final failures = <String>[];
      for (final selected in result.files) {
        if (selected.path == null) {
          failures.add(selected.name);
          continue;
        }
        try {
          await _libraryService.importFile(
            File(selected.path!),
            preferredName: selected.name,
          );
          imported++;
        } catch (_) {
          failures.add(selected.name);
        }
      }

      await _loadBooks();
      if (!mounted) return;
      if (failures.isEmpty) {
        _showMessage('已导入 $imported 本电子书');
      } else {
        _showMessage('已导入 $imported 本，${failures.length} 本失败', isError: true);
      }
    } catch (error) {
      if (mounted) _showMessage('导入失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _openBook(Ebook book) async {
    if (book.type == EbookType.pdf) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => PdfReaderScreen(book: book)),
      );
      await _loadBooks();
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 18),
              Expanded(child: Text('正在解析电子书…')),
            ],
          ),
        ),
      ),
    );

    try {
      final content = switch (book.type) {
        EbookType.epub => await const EpubService().parseFile(book.file.path),
        EbookType.mobi => await const MobiService().parseFile(book.file.path),
        EbookType.pdf => throw StateError('PDF 应直接使用 PDF 阅读器打开'),
      };
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ReflowableReaderScreen(book: book, content: content),
        ),
      );
      await _loadBooks();
    } catch (error) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showMessage('打开失败：$error', isError: true);
    }
  }

  Future<void> _deleteBook(Ebook book) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除电子书？'),
        content: Text('“${book.displayName}”将从本应用的书架中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;

    try {
      await _libraryService.deleteBook(book);
      await _progressStore?.removeFor(book.fileName);
      await _loadBooks();
    } catch (error) {
      if (mounted) _showMessage('删除失败：$error', isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    final colors = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? colors.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fluenca Reader'),
            Text('我的书架', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadBooks,
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _importBooks,
        icon: _importing
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_rounded),
        label: Text(_importing ? '导入中' : '导入电子书'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_stories_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text('书架还是空的', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                '导入 EPUB、PDF 或 MOBI 文件后即可开始阅读，\n阅读进度会自动保存在设备上。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 80),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadBooks,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        itemCount: _books.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final book = _books[index];
          return _BookCard(
            book: book,
            progress: _progressLabels[book.file.path],
            onOpen: () => _openBook(book),
            onDelete: () => _deleteBook(book),
          );
        },
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.progress,
    required this.onOpen,
    required this.onDelete,
  });

  final Ebook book;
  final String? progress;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final (label, accent, icon) = switch (book.type) {
      EbookType.epub => (
        'EPUB',
        Colors.indigo.shade600,
        Icons.menu_book_rounded,
      ),
      EbookType.pdf => (
        'PDF',
        Colors.red.shade700,
        Icons.picture_as_pdf_rounded,
      ),
      EbookType.mobi => (
        'MOBI',
        Colors.teal.shade700,
        Icons.auto_stories_rounded,
      ),
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 72,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 30, color: accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _TypeBadge(label: label, color: accent),
                        if (progress != null) ...[
                          const SizedBox(width: 10),
                          Icon(
                            Icons.schedule_rounded,
                            size: 15,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            progress!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  if (value == 'open') onOpen();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'open',
                    child: ListTile(
                      leading: Icon(Icons.chrome_reader_mode_outlined),
                      title: Text('打开'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('删除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
