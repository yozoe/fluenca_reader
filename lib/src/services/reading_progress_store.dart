import 'package:shared_preferences/shared_preferences.dart';

import '../models/ebook.dart';

class ReadingProgressStore {
  ReadingProgressStore._(this._preferences);

  final SharedPreferences _preferences;

  static Future<ReadingProgressStore> create() async {
    return ReadingProgressStore._(await SharedPreferences.getInstance());
  }

  int reflowableChapter(EbookType type, String fileName) {
    final prefix = _reflowablePrefix(type);
    return _preferences.getInt('${prefix}_${fileName}_chapter') ?? 0;
  }

  int? reflowableTotalChapters(EbookType type, String fileName) {
    final prefix = _reflowablePrefix(type);
    return _preferences.getInt('${prefix}_${fileName}_total');
  }

  int reflowableOffset(EbookType type, String fileName) {
    final prefix = _reflowablePrefix(type);
    return _preferences.getInt('${prefix}_${fileName}_offset') ?? 0;
  }

  double get reflowableFontSize {
    return _preferences.getDouble('reader_font_size') ??
        _preferences.getDouble('epub_font_size') ??
        17;
  }

  Future<void> saveReflowable({
    required EbookType type,
    required String fileName,
    required int chapter,
    required int offset,
    required int totalChapters,
    required double fontSize,
  }) async {
    final prefix = _reflowablePrefix(type);
    await Future.wait([
      _preferences.setInt('${prefix}_${fileName}_chapter', chapter),
      _preferences.setInt('${prefix}_${fileName}_offset', offset),
      _preferences.setInt('${prefix}_${fileName}_total', totalChapters),
      _preferences.setDouble('reader_font_size', fontSize),
    ]);
  }

  int pdfPage(String fileName) {
    return _preferences.getInt('pdf_page_$fileName') ?? 1;
  }

  int? pdfTotalPages(String fileName) {
    return _preferences.getInt('pdf_total_$fileName');
  }

  Future<void> savePdf({
    required String fileName,
    required int page,
    required int totalPages,
  }) async {
    await _preferences.setInt('pdf_page_$fileName', page);
    if (totalPages > 0) {
      await _preferences.setInt('pdf_total_$fileName', totalPages);
    }
  }

  Future<void> savePdfTotalPages({
    required String fileName,
    required int totalPages,
  }) async {
    if (totalPages > 0) {
      await _preferences.setInt('pdf_total_$fileName', totalPages);
    }
  }

  Future<void> removeFor(String fileName) async {
    await Future.wait([
      _preferences.remove('epub_${fileName}_chapter'),
      _preferences.remove('epub_${fileName}_total'),
      _preferences.remove('epub_${fileName}_offset'),
      _preferences.remove('mobi_${fileName}_chapter'),
      _preferences.remove('mobi_${fileName}_total'),
      _preferences.remove('mobi_${fileName}_offset'),
      _preferences.remove('pdf_page_$fileName'),
      _preferences.remove('pdf_total_$fileName'),
    ]);
  }

  String _reflowablePrefix(EbookType type) {
    return switch (type) {
      EbookType.epub => 'epub',
      EbookType.mobi => 'mobi',
      EbookType.pdf => throw ArgumentError.value(
        type,
        'type',
        'PDF 使用页码进度，不能使用章节进度',
      ),
    };
  }
}
