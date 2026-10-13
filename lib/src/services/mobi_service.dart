import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;

import '../models/ebook.dart';

class MobiService {
  const MobiService({
    this.maxFileBytes = 200 * 1024 * 1024,
    this.maxTextBytes = 100 * 1024 * 1024,
    this.maxRecords = 10000,
    this.maxChapters = 2000,
  }) : assert(maxFileBytes > 0),
       assert(maxTextBytes > 0),
       assert(maxRecords > 0),
       assert(maxChapters > 0);

  final int maxFileBytes;
  final int maxTextBytes;
  final int maxRecords;
  final int maxChapters;

  Future<ReflowableBook> parseFile(String filePath) async {
    final fileLimit = maxFileBytes;
    final textLimit = maxTextBytes;
    final recordLimit = maxRecords;
    final chapterLimit = maxChapters;
    return Isolate.run(
      () => _parseFile(
        filePath,
        maxFileBytes: fileLimit,
        maxTextBytes: textLimit,
        maxRecords: recordLimit,
        maxChapters: chapterLimit,
      ),
    );
  }

  static Future<ReflowableBook> _parseFile(
    String filePath, {
    required int maxFileBytes,
    required int maxTextBytes,
    required int maxRecords,
    required int maxChapters,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) throw const MobiException('MOBI 文件不存在');
    final fileSize = await file.length();
    if (fileSize > maxFileBytes) {
      throw MobiException('MOBI 文件过大（最大 ${_formatBytes(maxFileBytes)}）');
    }

    try {
      final bytes = await file.readAsBytes();
      if (bytes.length < 78) throw const MobiException('无效的 MOBI 文件头');

      final recordCount = _uint16(bytes, 76);
      if (recordCount < 2 || recordCount > maxRecords) {
        throw MobiException('MOBI 记录数量无效（最大 $maxRecords 个）');
      }
      final recordTableEnd = 78 + recordCount * 8;
      if (recordTableEnd > bytes.length) {
        throw const MobiException('MOBI 记录表不完整');
      }

      final recordOffsets = <int>[];
      for (var index = 0; index < recordCount; index++) {
        recordOffsets.add(_uint32(bytes, 78 + index * 8));
      }
      _validateRecordOffsets(recordOffsets, recordTableEnd, bytes.length);

      final record0 = _record(bytes, recordOffsets, 0);
      if (record0.length < 132 || _ascii(record0, 16, 4) != 'MOBI') {
        throw const MobiException('文件不是受支持的 Mobipocket 电子书');
      }

      final compression = _uint16(record0, 0);
      final textLength = _uint32(record0, 4);
      final textRecordCount = _uint16(record0, 8);
      final textRecordSize = _uint16(record0, 10);
      final encryption = _uint16(record0, 12);
      if (encryption != 0) {
        throw const MobiException('不支持带 DRM 或加密的 MOBI 文件');
      }
      if (textLength <= 0 || textLength > maxTextBytes) {
        throw MobiException('MOBI 文本内容过大（最大 ${_formatBytes(maxTextBytes)}）');
      }
      if (textRecordCount <= 0 || textRecordCount >= recordOffsets.length) {
        throw const MobiException('MOBI 文本记录不完整');
      }
      if (textRecordSize <= 0) {
        throw const MobiException('MOBI 文本记录大小无效');
      }
      if (compression != 1 && compression != 2) {
        if (compression == 17480) {
          throw const MobiException('暂不支持 Huff/CDIC 压缩的 MOBI 文件');
        }
        throw MobiException('不支持的 MOBI 压缩方式：$compression');
      }

      final mobiHeaderLength = _uint32(record0, 20);
      if (mobiHeaderLength < 116 || 16 + mobiHeaderLength > record0.length) {
        throw const MobiException('MOBI 元数据头不完整');
      }
      final encoding = _uint32(record0, 28);
      final fullNameOffset = _uint32(record0, 84);
      final fullNameLength = _uint32(record0, 88);
      final exthFlags = mobiHeaderLength >= 116 ? _uint32(record0, 128) : 0;
      final extraFlags = mobiHeaderLength >= 228 ? _uint16(record0, 242) : 0;

      final metadata = _readExthMetadata(
        record0,
        headerLength: mobiHeaderLength,
        exthFlags: exthFlags,
      );
      final fullName = _decodeRange(
        record0,
        fullNameOffset,
        fullNameLength,
        encoding,
      );
      final title =
          _firstMetadata(metadata, const [503]) ??
          _cleanMetadata(fullName) ??
          path.basenameWithoutExtension(filePath);
      final authors = _metadataValues(metadata, const [100]);
      final author = authors.isEmpty ? '未知作者' : authors.join('、');

      final output = BytesBuilder(copy: false);
      var outputLength = 0;
      for (var index = 1; index <= textRecordCount; index++) {
        final rawRecord = _record(bytes, recordOffsets, index);
        final trailingSize = _trailingDataSize(rawRecord, extraFlags);
        if (trailingSize > rawRecord.length) {
          throw const MobiException('MOBI 文本记录尾部数据损坏');
        }
        final content = Uint8List.sublistView(
          rawRecord,
          0,
          rawRecord.length - trailingSize,
        );
        final decodedRecord = compression == 1
            ? Uint8List.fromList(content)
            : _decompressPalmDoc(
                content,
                maxOutputBytes: math.min(
                  textRecordSize,
                  maxTextBytes - outputLength,
                ),
              );
        if (decodedRecord.length > textRecordSize) {
          throw const MobiException('MOBI 文本记录超过声明大小');
        }
        outputLength += decodedRecord.length;
        if (outputLength > maxTextBytes) {
          throw MobiException('MOBI 文本内容过大（最大 ${_formatBytes(maxTextBytes)}）');
        }
        output.add(decodedRecord);
      }

      var textBytes = output.takeBytes();
      if (textBytes.length < textLength) {
        throw const MobiException('MOBI 文本内容不完整');
      }
      if (textBytes.length > textLength) {
        textBytes = Uint8List.sublistView(textBytes, 0, textLength);
      }
      if (textBytes.isEmpty) throw const MobiException('MOBI 中没有可阅读文本');

      final markup = _decodeText(textBytes, encoding).replaceAll('\u0000', '');
      final chapters = _extractChapters(
        markup,
        textBytes: textBytes,
        encoding: encoding,
        bookTitle: title,
        maxChapters: maxChapters,
      );
      if (chapters.isEmpty) {
        throw const MobiException('MOBI 中没有可阅读章节');
      }

      return ReflowableBook(title: title, author: author, chapters: chapters);
    } on MobiException {
      rethrow;
    } on FormatException catch (error) {
      throw MobiException('MOBI 文件格式错误：$error');
    } on RangeError catch (error) {
      throw MobiException('MOBI 文件数据不完整：$error');
    }
  }

  static void _validateRecordOffsets(
    List<int> offsets,
    int tableEnd,
    int fileLength,
  ) {
    var previous = tableEnd;
    for (final offset in offsets) {
      if (offset < previous || offset > fileLength) {
        throw const MobiException('MOBI 记录偏移无效');
      }
      previous = offset;
    }
  }

  static Uint8List _record(Uint8List bytes, List<int> offsets, int index) {
    if (index < 0 || index >= offsets.length) {
      throw const MobiException('MOBI 记录索引无效');
    }
    final start = offsets[index];
    final end = index + 1 < offsets.length ? offsets[index + 1] : bytes.length;
    return Uint8List.sublistView(bytes, start, end);
  }

  static Map<int, List<Uint8List>> _readExthMetadata(
    Uint8List record0, {
    required int headerLength,
    required int exthFlags,
  }) {
    if ((exthFlags & 0x40) == 0) return const {};
    final start = 16 + headerLength;
    if (start + 12 > record0.length || _ascii(record0, start, 4) != 'EXTH') {
      return const {};
    }
    final length = _uint32(record0, start + 4);
    final count = _uint32(record0, start + 8);
    if (length < 12 || start + length > record0.length || count > 10000) {
      return const {};
    }

    final metadata = <int, List<Uint8List>>{};
    var offset = start + 12;
    for (var index = 0; index < count; index++) {
      if (offset + 8 > start + length) break;
      final type = _uint32(record0, offset);
      final size = _uint32(record0, offset + 4);
      if (size < 8 || offset + size > start + length) break;
      metadata
          .putIfAbsent(type, () => [])
          .add(Uint8List.sublistView(record0, offset + 8, offset + size));
      offset += size;
    }
    return metadata;
  }

  static String? _firstMetadata(
    Map<int, List<Uint8List>> metadata,
    List<int> tags,
  ) {
    for (final tag in tags) {
      for (final bytes in metadata[tag] ?? const <Uint8List>[]) {
        final value = _cleanMetadata(utf8.decode(bytes, allowMalformed: true));
        if (value != null) return value;
      }
    }
    return null;
  }

  static List<String> _metadataValues(
    Map<int, List<Uint8List>> metadata,
    List<int> tags,
  ) {
    for (final tag in tags) {
      final values = (metadata[tag] ?? const <Uint8List>[])
          .map((bytes) => utf8.decode(bytes, allowMalformed: true))
          .map(_cleanMetadata)
          .whereType<String>()
          .toSet()
          .toList();
      if (values.isNotEmpty) return values;
    }
    return const [];
  }

  static String? _cleanMetadata(String? value) {
    if (value == null) return null;
    final decoded = html_parser.parseFragment(value).text ?? value;
    final cleaned = decoded.replaceAll('\u0000', '').trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  static String? _decodeRange(
    Uint8List bytes,
    int offset,
    int length,
    int encoding,
  ) {
    if (offset <= 0 || length <= 0 || offset + length > bytes.length) {
      return null;
    }
    return _decodeText(
      Uint8List.sublistView(bytes, offset, offset + length),
      encoding,
    );
  }

  static int _trailingDataSize(Uint8List record, int extraFlags) {
    if (record.isEmpty || extraFlags == 0) return 0;
    var size = 0;
    var trailingFlags = extraFlags >> 1;
    while (trailingFlags != 0) {
      if ((trailingFlags & 1) != 0) {
        final entrySize = _backwardVariableWidthValue(
          record,
          record.length - size,
        );
        if (entrySize <= 0 || entrySize > record.length - size) {
          throw const MobiException('MOBI 尾部数据长度无效');
        }
        size += entrySize;
      }
      trailingFlags >>= 1;
    }
    if ((extraFlags & 1) != 0) {
      final index = record.length - size - 1;
      if (index < 0) throw const MobiException('MOBI 多字节尾部数据无效');
      size += (record[index] & 0x03) + 1;
    }
    return size;
  }

  static int _backwardVariableWidthValue(Uint8List data, int endExclusive) {
    var value = 0;
    var index = endExclusive - 1;
    for (var count = 0; count < 4 && index >= 0; count++, index--) {
      final byte = data[index];
      value = (value << 7) | (byte & 0x7f);
      if ((byte & 0x80) != 0) return value;
    }
    throw const MobiException('MOBI 可变长度尾部数据无效');
  }

  static Uint8List _decompressPalmDoc(
    Uint8List input, {
    required int maxOutputBytes,
  }) {
    final output = <int>[];
    var index = 0;
    while (index < input.length) {
      final byte = input[index++];
      if (byte == 0 || (byte >= 0x09 && byte <= 0x7f)) {
        output.add(byte);
      } else if (byte <= 0x08) {
        if (index + byte > input.length) {
          throw const MobiException('PalmDOC 字面量数据不完整');
        }
        output.addAll(input.sublist(index, index + byte));
        index += byte;
      } else if (byte <= 0xbf) {
        if (index >= input.length) {
          throw const MobiException('PalmDOC 回溯数据不完整');
        }
        final pair = (byte << 8) | input[index++];
        final distance = (pair >> 3) & 0x07ff;
        final length = (pair & 0x07) + 3;
        if (distance == 0 || distance > output.length) {
          throw const MobiException('PalmDOC 回溯距离无效');
        }
        for (var copied = 0; copied < length; copied++) {
          output.add(output[output.length - distance]);
        }
      } else {
        output
          ..add(0x20)
          ..add(byte ^ 0x80);
      }
      if (output.length > maxOutputBytes) {
        throw const MobiException('PalmDOC 解压内容超过限制');
      }
    }
    return Uint8List.fromList(output);
  }

  static String _decodeText(Uint8List bytes, int encoding) {
    return switch (encoding) {
      1252 => String.fromCharCodes(bytes.map(_windows1252CodePoint)),
      65002 => _decodeUtf16(bytes),
      _ => utf8.decode(bytes, allowMalformed: true),
    };
  }

  static int _windows1252CodePoint(int byte) {
    if (byte < 0x80 || byte >= 0xa0) return byte;
    const replacements = <int>[
      0x20ac,
      0x0081,
      0x201a,
      0x0192,
      0x201e,
      0x2026,
      0x2020,
      0x2021,
      0x02c6,
      0x2030,
      0x0160,
      0x2039,
      0x0152,
      0x008d,
      0x017d,
      0x008f,
      0x0090,
      0x2018,
      0x2019,
      0x201c,
      0x201d,
      0x2022,
      0x2013,
      0x2014,
      0x02dc,
      0x2122,
      0x0161,
      0x203a,
      0x0153,
      0x009d,
      0x017e,
      0x0178,
    ];
    return replacements[byte - 0x80];
  }

  static String _decodeUtf16(Uint8List bytes) {
    if (bytes.length < 2) return '';
    var littleEndian = false;
    var offset = 0;
    if (bytes[0] == 0xff && bytes[1] == 0xfe) {
      littleEndian = true;
      offset = 2;
    } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
      offset = 2;
    }
    final codeUnits = <int>[];
    for (; offset + 1 < bytes.length; offset += 2) {
      codeUnits.add(
        littleEndian
            ? bytes[offset] | (bytes[offset + 1] << 8)
            : (bytes[offset] << 8) | bytes[offset + 1],
      );
    }
    return String.fromCharCodes(codeUnits);
  }

  static List<ReflowableChapter> _extractChapters(
    String markup, {
    required Uint8List textBytes,
    required int encoding,
    required String bookTitle,
    required int maxChapters,
  }) {
    final chunks = markup.split(
      RegExp(r'<(?:mbp:)?pagebreak\b[^>]*?/?>', caseSensitive: false),
    );
    final pageBreakChapters = _chaptersFromSources(
      chunks.map((chunk) => _MobiChapterSource(markup: chunk)),
      bookTitle: bookTitle,
      maxChapters: maxChapters,
    );
    if (pageBreakChapters.length > 1) return pageBreakChapters;

    final fileposChapters = _extractFileposChapters(
      markup,
      textBytes: textBytes,
      encoding: encoding,
      bookTitle: bookTitle,
      maxChapters: maxChapters,
    );
    return fileposChapters.isEmpty ? pageBreakChapters : fileposChapters;
  }

  static List<ReflowableChapter> _extractFileposChapters(
    String markup, {
    required Uint8List textBytes,
    required int encoding,
    required String bookTitle,
    required int maxChapters,
  }) {
    final document = html_parser.parse(markup);
    var navigationAnchors = document.querySelectorAll('a[filepos]');
    var selectedContainerIsNamed = false;
    var selectedDescendantCount = 1 << 30;
    for (final container in document.querySelectorAll(
      'nav, ol, ul, table, div',
    )) {
      final anchors = container.querySelectorAll('a[filepos]');
      if (anchors.length < 2) continue;
      final marker = [
        container.localName,
        container.id,
        container.className,
        container.attributes['role'],
        container.attributes['title'],
        container.attributes['aria-label'],
      ].whereType<String>().join(' ').toLowerCase();
      final isNamedContainer =
          marker.contains('toc') || marker.contains('content');
      final descendantCount = container.querySelectorAll('*').length;
      if ((isNamedContainer && !selectedContainerIsNamed) ||
          (isNamedContainer == selectedContainerIsNamed &&
              descendantCount < selectedDescendantCount)) {
        navigationAnchors = anchors;
        selectedContainerIsNamed = isNamedContainer;
        selectedDescendantCount = descendantCount;
      }
    }

    final targets = <int, String>{};
    for (final anchor in navigationAnchors) {
      final rawPosition = anchor.attributes['filepos']?.trim();
      if (rawPosition == null || !RegExp(r'^\d+$').hasMatch(rawPosition)) {
        continue;
      }
      final position = int.tryParse(rawPosition);
      final title = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (position == null ||
          position < 0 ||
          position >= textBytes.length ||
          title.isEmpty) {
        continue;
      }
      targets.putIfAbsent(position, () => title);
    }
    if (targets.length < 2) return const [];

    final positions = targets.keys.toList()..sort();
    final sources = <_MobiChapterSource>[];
    if (positions.first > 0) {
      final prefixMarkup = _decodeText(
        Uint8List.sublistView(textBytes, 0, positions.first),
        encoding,
      );
      if (_containsNonNavigationText(prefixMarkup)) {
        sources.add(
          _MobiChapterSource(markup: prefixMarkup, suggestedTitle: bookTitle),
        );
      }
    }
    for (var index = 0; index < positions.length; index++) {
      final start = positions[index];
      final end = index + 1 < positions.length
          ? positions[index + 1]
          : textBytes.length;
      sources.add(
        _MobiChapterSource(
          markup: _decodeText(
            Uint8List.sublistView(textBytes, start, end),
            encoding,
          ),
          suggestedTitle: targets[start],
        ),
      );
    }
    return _chaptersFromSources(
      sources,
      bookTitle: bookTitle,
      maxChapters: maxChapters,
    );
  }

  static bool _containsNonNavigationText(String markup) {
    final document = html_parser.parse(markup);
    final body = document.body;
    if (body == null) return false;
    for (final element in body.querySelectorAll('a[filepos], script, style')) {
      element.remove();
    }
    return body.text.replaceAll(RegExp(r'\s+'), ' ').trim().isNotEmpty;
  }

  static List<ReflowableChapter> _chaptersFromSources(
    Iterable<_MobiChapterSource> sources, {
    required String bookTitle,
    required int maxChapters,
  }) {
    final chapters = <ReflowableChapter>[];
    for (final source in sources) {
      final document = html_parser.parse(source.markup);
      final body = document.body;
      if (body == null) continue;
      for (final hidden in body.querySelectorAll('script, style')) {
        hidden.remove();
      }
      final readableText = (body.text)
          .replaceAll('\u00a0', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (readableText.isEmpty) continue;
      if (chapters.length >= maxChapters) {
        throw MobiException('MOBI 章节数量过多（最大 $maxChapters 章）');
      }

      final heading = body.querySelector('h1, h2, h3');
      final headingText = heading?.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final suggestedTitle = source.suggestedTitle?.trim();
      chapters.add(
        ReflowableChapter(
          title: suggestedTitle != null && suggestedTitle.isNotEmpty
              ? suggestedTitle
              : headingText == null || headingText.isEmpty
              ? (chapters.isEmpty ? bookTitle : '第 ${chapters.length + 1} 节')
              : headingText,
          html: body.innerHtml,
          order: chapters.length,
        ),
      );
    }
    return chapters;
  }

  static int _uint16(Uint8List bytes, int offset) {
    _requireRange(bytes, offset, 2);
    return ByteData.sublistView(bytes, offset, offset + 2).getUint16(0);
  }

  static int _uint32(Uint8List bytes, int offset) {
    _requireRange(bytes, offset, 4);
    return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
  }

  static String _ascii(Uint8List bytes, int offset, int length) {
    _requireRange(bytes, offset, length);
    return ascii.decode(
      Uint8List.sublistView(bytes, offset, offset + length),
      allowInvalid: true,
    );
  }

  static void _requireRange(Uint8List bytes, int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw const MobiException('MOBI 字段超出文件范围');
    }
  }

  static String _formatBytes(int bytes) {
    final megabytes = bytes / (1024 * 1024);
    return '${math.max(1, megabytes.ceil())} MB';
  }
}

class _MobiChapterSource {
  const _MobiChapterSource({required this.markup, this.suggestedTitle});

  final String markup;
  final String? suggestedTitle;
}

class MobiException implements Exception {
  const MobiException(this.message);

  final String message;

  @override
  String toString() => message;
}
