import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluenca_reader/src/services/mobi_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('MobiService', () {
    late Directory temporaryDirectory;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'fluenca_reader_mobi_test_',
      );
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    for (final compression in [1, 2]) {
      test('parses compression $compression MOBI text and chapters', () async {
        const markup = '''
<html><body><h1>First chapter</h1><p>Hello reader.</p></body></html>
<mbp:pagebreak/>
<html><body><h2>Second chapter</h2><p>Goodbye reader.</p></body></html>
''';
        final file = File(
          path.join(temporaryDirectory.path, 'Synthetic Book.mobi'),
        );
        await file.writeAsBytes(
          _buildMobi(
            textRecords: [utf8.encode(markup)],
            compression: compression,
          ),
        );

        final book = await const MobiService().parseFile(file.path);

        expect(book.title, 'Synthetic Book');
        expect(book.author, '未知作者');
        expect(book.chapters, hasLength(2));
        expect(book.chapters[0].title, 'First chapter');
        expect(book.chapters[0].html, contains('Hello reader.'));
        expect(book.chapters[1].title, 'Second chapter');
        expect(book.chapters[1].html, contains('Goodbye reader.'));
      });
    }

    test('decompresses PalmDOC back-references', () async {
      const prefix = '<html><body><p>Hello ';
      const suffix = '</p></body></html>';
      const markup = '${prefix}Hello$suffix';
      final compressed = <int>[
        ...ascii.encode(prefix),
        0x80,
        0x32,
        ...ascii.encode(suffix),
      ];
      final file = File(path.join(temporaryDirectory.path, 'backref.mobi'));
      await file.writeAsBytes(
        _buildMobi(
          textRecords: [compressed],
          textLength: utf8.encode(markup).length,
          compression: 2,
        ),
      );

      final book = await const MobiService().parseFile(file.path);

      expect(book.chapters.single.html, contains('Hello Hello'));
    });

    test('reads EXTH metadata from a minimum-length MOBI header', () async {
      final file = File(path.join(temporaryDirectory.path, 'metadata.mobi'));
      await file.writeAsBytes(
        _buildMobi(
          textRecords: [
            utf8.encode('<html><body><p>Metadata</p></body></html>'),
          ],
          compression: 1,
          exthMetadata: const {
            503: ['Short Header Title'],
            100: ['Short Header Author'],
          },
        ),
      );

      final book = await const MobiService().parseFile(file.path);

      expect(book.title, 'Short Header Title');
      expect(book.author, 'Short Header Author');
    });

    test('removes trailing data with a 228-byte MOBI header', () async {
      const first = '<html><body><p>First';
      const second = ' and second.</p></body></html>';
      final file = File(path.join(temporaryDirectory.path, 'trailing.mobi'));
      await file.writeAsBytes(
        _buildMobi(
          textRecords: [
            [...utf8.encode(first), 0x7e, 0x01],
            [...utf8.encode(second), 0x7e, 0x01],
          ],
          textLength: utf8.encode('$first$second').length,
          compression: 1,
          mobiHeaderLength: 228,
          extraFlags: 1,
        ),
      );

      final book = await const MobiService().parseFile(file.path);

      expect(book.chapters.single.html, contains('First and second.'));
      expect(book.chapters.single.html, isNot(contains('~')));
    });

    test('uses classic filepos links when pagebreak tags are absent', () async {
      final markup = _fileposBookMarkup();
      final file = File(path.join(temporaryDirectory.path, 'filepos.mobi'));
      await file.writeAsBytes(
        _buildMobi(textRecords: [utf8.encode(markup)], compression: 1),
      );

      final book = await const MobiService().parseFile(file.path);

      expect(book.chapters, hasLength(2));
      expect(book.chapters.map((chapter) => chapter.title), ['One', 'Two']);
      expect(book.chapters[0].html, contains('First body'));
      expect(book.chapters[1].html, contains('Second body'));
    });

    test('reports the chapter limit instead of truncating content', () async {
      const markup = '''
<html><body><p>One</p></body></html><mbp:pagebreak/>
<html><body><p>Two</p></body></html><mbp:pagebreak/>
<html><body><p>Three</p></body></html>
''';
      final file = File(path.join(temporaryDirectory.path, 'many.mobi'));
      await file.writeAsBytes(
        _buildMobi(textRecords: [utf8.encode(markup)], compression: 1),
      );

      expect(
        () => const MobiService(maxChapters: 2).parseFile(file.path),
        throwsA(
          isA<MobiException>().having(
            (error) => error.message,
            'message',
            contains('最大 2 章'),
          ),
        ),
      );
    });

    test('rejects encrypted or DRM-protected MOBI files', () async {
      final file = File(path.join(temporaryDirectory.path, 'protected.mobi'));
      await file.writeAsBytes(
        _buildMobi(
          textRecords: [utf8.encode('<html><body>Protected</body></html>')],
          compression: 1,
          encryption: 1,
        ),
      );

      expect(
        () => const MobiService().parseFile(file.path),
        throwsA(
          isA<MobiException>().having(
            (error) => error.message,
            'message',
            contains('DRM'),
          ),
        ),
      );
    });

    test('rejects Huff/CDIC compression with a clear error', () async {
      final file = File(path.join(temporaryDirectory.path, 'huff.mobi'));
      await file.writeAsBytes(
        _buildMobi(
          textRecords: [utf8.encode('<html><body>Huff</body></html>')],
          compression: 17480,
        ),
      );

      expect(
        () => const MobiService().parseFile(file.path),
        throwsA(
          isA<MobiException>().having(
            (error) => error.message,
            'message',
            contains('Huff/CDIC'),
          ),
        ),
      );
    });
  });
}

Uint8List _buildMobi({
  required List<List<int>> textRecords,
  required int compression,
  int encryption = 0,
  int? textLength,
  int mobiHeaderLength = 116,
  int extraFlags = 0,
  Map<int, List<String>> exthMetadata = const {},
}) {
  const pdbHeaderLength = 78;
  final exth = _buildExth(exthMetadata);
  final recordCount = textRecords.length + 1;
  final recordTableLength = recordCount * 8;
  final record0Length = 16 + mobiHeaderLength + exth.length;
  final record0Offset = pdbHeaderLength + recordTableLength + 2;
  final recordOffsets = <int>[record0Offset];
  var nextOffset = record0Offset + record0Length;
  for (final record in textRecords) {
    recordOffsets.add(nextOffset);
    nextOffset += record.length;
  }
  final bytes = Uint8List(nextOffset);
  final data = ByteData.sublistView(bytes);

  final databaseName = ascii.encode('Synthetic MOBI');
  bytes.setRange(0, databaseName.length, databaseName);
  bytes.setRange(60, 68, ascii.encode('BOOKMOBI'));
  data.setUint16(76, recordCount);
  for (var index = 0; index < recordOffsets.length; index++) {
    data.setUint32(78 + index * 8, recordOffsets[index]);
  }

  data.setUint16(record0Offset, compression);
  data.setUint32(
    record0Offset + 4,
    textLength ?? textRecords.fold(0, (total, record) => total + record.length),
  );
  data.setUint16(record0Offset + 8, textRecords.length);
  data.setUint16(record0Offset + 10, 4096);
  data.setUint16(record0Offset + 12, encryption);
  bytes.setRange(record0Offset + 16, record0Offset + 20, ascii.encode('MOBI'));
  data.setUint32(record0Offset + 20, mobiHeaderLength);
  data.setUint32(record0Offset + 28, 65001);
  data.setUint32(record0Offset + 36, 6);
  if (exth.isNotEmpty) {
    data.setUint32(record0Offset + 128, 0x40);
    bytes.setRange(
      record0Offset + 16 + mobiHeaderLength,
      record0Offset + record0Length,
      exth,
    );
  }
  if (extraFlags != 0) {
    if (mobiHeaderLength < 228) {
      throw ArgumentError.value(mobiHeaderLength, 'mobiHeaderLength');
    }
    data.setUint16(record0Offset + 242, extraFlags);
  }
  for (var index = 0; index < textRecords.length; index++) {
    final start = recordOffsets[index + 1];
    bytes.setRange(
      start,
      start + textRecords[index].length,
      textRecords[index],
    );
  }
  return bytes;
}

Uint8List _buildExth(Map<int, List<String>> metadata) {
  if (metadata.isEmpty) return Uint8List(0);
  final entries = <Uint8List>[];
  for (final metadataEntry in metadata.entries) {
    for (final value in metadataEntry.value) {
      final payload = utf8.encode(value);
      final entry = Uint8List(8 + payload.length);
      final data = ByteData.sublistView(entry);
      data.setUint32(0, metadataEntry.key);
      data.setUint32(4, entry.length);
      entry.setRange(8, entry.length, payload);
      entries.add(entry);
    }
  }
  final length =
      12 + entries.fold<int>(0, (total, entry) => total + entry.length);
  final exth = Uint8List(length);
  final data = ByteData.sublistView(exth);
  exth.setRange(0, 4, ascii.encode('EXTH'));
  data.setUint32(4, length);
  data.setUint32(8, entries.length);
  var offset = 12;
  for (final entry in entries) {
    exth.setRange(offset, offset + entry.length, entry);
    offset += entry.length;
  }
  return exth;
}

String _fileposBookMarkup() {
  const placeholder = '0000000000';
  var markup =
      '''
<html><body><div id="toc">
<a filepos="$placeholder">One</a>
<a filepos="$placeholder">Two</a>
</div><h1>One</h1><p>First body</p>
<h1>Two</h1><p>Second body</p>
<p><a filepos="$placeholder">Footnote link</a></p></body></html>
''';
  final firstPosition = utf8
      .encode(markup.substring(0, markup.indexOf('<h1>One')))
      .length;
  final secondPosition = utf8
      .encode(markup.substring(0, markup.indexOf('<h1>Two')))
      .length;
  markup = markup.replaceFirst(
    placeholder,
    firstPosition.toString().padLeft(placeholder.length, '0'),
  );
  return markup.replaceFirst(
    placeholder,
    secondPosition.toString().padLeft(placeholder.length, '0'),
  );
}
