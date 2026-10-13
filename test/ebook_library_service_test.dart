import 'dart:io';

import 'package:fluenca_reader/src/models/ebook.dart';
import 'package:fluenca_reader/src/services/ebook_library_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('EbookLibraryService', () {
    late Directory temporaryDirectory;
    late Directory libraryDirectory;
    late EbookLibraryService service;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'fluenca_reader_test_',
      );
      libraryDirectory = Directory(path.join(temporaryDirectory.path, 'books'));
      service = EbookLibraryService(libraryDirectory: libraryDirectory);
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('recognizes supported formats case-insensitively', () {
      expect(EbookLibraryService.typeForPath('book.EPUB'), EbookType.epub);
      expect(EbookLibraryService.typeForPath('paper.Pdf'), EbookType.pdf);
      expect(EbookLibraryService.typeForPath('novel.MOBI'), EbookType.mobi);
      expect(EbookLibraryService.typeForPath('notes.txt'), isNull);
    });

    test('imports, de-duplicates, sorts, and deletes books', () async {
      final epubSource = File(path.join(temporaryDirectory.path, 'Zulu.epub'));
      final pdfSource = File(path.join(temporaryDirectory.path, 'alpha.pdf'));
      await epubSource.writeAsString('epub');
      await pdfSource.writeAsString('pdf');

      final first = await service.importFile(epubSource);
      final duplicate = await service.importFile(epubSource);
      await service.importFile(pdfSource);
      await File(
        path.join(libraryDirectory.path, 'ignored.txt'),
      ).writeAsString('ignore me');

      final books = await service.loadBooks();
      expect(books.map((book) => book.fileName), [
        'alpha.pdf',
        'Zulu (2).epub',
        'Zulu.epub',
      ]);
      expect(first.type, EbookType.epub);
      expect(duplicate.fileName, 'Zulu (2).epub');

      await service.deleteBook(first);
      expect(await first.file.exists(), isFalse);
    });

    test('rejects unsupported files', () async {
      final textFile = File(path.join(temporaryDirectory.path, 'notes.txt'));
      await textFile.writeAsString('text');

      expect(
        () => service.importFile(textFile),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
