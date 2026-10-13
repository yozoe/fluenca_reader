import 'dart:convert';
import 'dart:io';

import 'package:fluenca_reader/src/models/ebook.dart';
import 'package:fluenca_reader/src/services/ebook_library_service.dart';
import 'package:fluenca_reader/src/services/epub_service.dart';
import 'package:fluenca_reader/src/services/mobi_service.dart';
import 'package:flutter_test/flutter_test.dart';

const fixtureDirectory = 'test/fixtures/books';

void main() {
  final pdf = File('$fixtureDirectory/Jane+Eyre.pdf');
  final epub = File(
    '$fixtureDirectory/Harry Potter and the Goblet of - J.K. Rowling.epub',
  );
  final mobi = File('$fixtureDirectory/Call+Me+by+Your+Name.mobi');

  test('recognizes the real PDF fixture', () async {
    final header = await pdf
        .openRead(0, 5)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));

    expect(utf8.decode(header), '%PDF-');
    expect(EbookLibraryService.typeForPath(pdf.path), EbookType.pdf);
  }, skip: _skipWhenMissing(pdf));

  test(
    'parses the real EPUB fixture off the UI isolate',
    () async {
      final book = await const EpubService().parseFile(epub.path);

      expect(book.title, isNotEmpty);
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.every((chapter) => chapter.html.isNotEmpty), isTrue);
    },
    skip: _skipWhenMissing(epub),
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'parses the real MOBI fixture off the UI isolate',
    () async {
      final book = await const MobiService().parseFile(mobi.path);

      expect(EbookLibraryService.typeForPath(mobi.path), EbookType.mobi);
      expect(book.title, startsWith('Call Me by Your Name'));
      expect(book.author, contains('André'));
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.every((chapter) => chapter.html.isNotEmpty), isTrue);
    },
    skip: _skipWhenMissing(mobi),
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

Object _skipWhenMissing(File file) {
  return file.existsSync() ? false : '本地测试文件不存在：${file.path}';
}
