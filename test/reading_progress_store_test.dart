import 'package:fluenca_reader/src/models/ebook.dart';
import 'package:fluenca_reader/src/services/reading_progress_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('saving PDF page count does not overwrite the restored page', () async {
    SharedPreferences.setMockInitialValues({
      'pdf_page_book.pdf': 37,
      'pdf_total_book.pdf': 100,
    });
    final store = await ReadingProgressStore.create();

    await store.savePdfTotalPages(fileName: 'book.pdf', totalPages: 120);

    expect(store.pdfPage('book.pdf'), 37);
    expect(store.pdfTotalPages('book.pdf'), 120);
  });

  test('saves the stable text offset for a reflowable book', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await ReadingProgressStore.create();

    await store.saveReflowable(
      type: EbookType.mobi,
      fileName: 'book.mobi',
      chapter: 3,
      offset: 4280,
      totalChapters: 12,
      fontSize: 19,
    );

    expect(store.reflowableChapter(EbookType.mobi, 'book.mobi'), 3);
    expect(store.reflowableOffset(EbookType.mobi, 'book.mobi'), 4280);
    expect(store.reflowableTotalChapters(EbookType.mobi, 'book.mobi'), 12);
  });
}
