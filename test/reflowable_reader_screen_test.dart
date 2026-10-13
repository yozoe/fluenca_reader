import 'dart:io';

import 'package:fluenca_reader/src/models/ebook.dart';
import 'package:fluenca_reader/src/screens/reflowable_reader_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('does not render an identical chapter heading twice', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final book = Ebook(
      file: File('/tmp/repeated-heading.mobi'),
      type: EbookType.mobi,
    );
    const content = ReflowableBook(
      title: 'Book title',
      author: 'Book author',
      chapters: [
        ReflowableChapter(
          title: 'Repeated heading',
          html: '<h1>Repeated heading</h1><p>Body copy.</p>',
          order: 0,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ReflowableReaderScreen(book: book, content: content),
      ),
    );
    await tester.pumpAndSettle();

    final renderedText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(RegExp('Repeated heading').allMatches(renderedText), hasLength(1));
    expect(renderedText, contains('Body copy.'));
    final bodyText = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere((widget) => widget.data == 'Body copy.');
    expect(bodyText.style?.color, isNot(const Color(0xFFFF0000)));
    expect(bodyText.style?.decoration, isNot(TextDecoration.underline));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('paginates long chapter text to the screen viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    final book = Ebook(
      file: File('/tmp/long-chapter.mobi'),
      type: EbookType.mobi,
    );
    final body = List.filled(
      300,
      'This paragraph must be split across actual screen pages.',
    ).join(' ');
    final content = ReflowableBook(
      title: 'Paginated book',
      author: 'Book author',
      chapters: [
        ReflowableChapter(
          title: 'Long chapter',
          html: '<h1>Long chapter</h1><p>$body</p>',
          order: 0,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ReflowableReaderScreen(book: book, content: content),
      ),
    );
    await tester.pumpAndSettle();

    final firstIndicator = tester.widget<Text>(
      find.byKey(const Key('reader-page-indicator')),
    );
    final match = RegExp(r'^1 / (\d+) 页$').firstMatch(firstIndicator.data!);
    expect(match, isNotNull);
    expect(int.parse(match!.group(1)!), greaterThan(12));
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();

    final secondIndicator = tester.widget<Text>(
      find.byKey(const Key('reader-page-indicator')),
    );
    expect(secondIndicator.data, startsWith('2 / '));

    for (var page = 0; page < 12; page++) {
      await tester.tap(find.byTooltip('下一页'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
