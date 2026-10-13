import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../models/ebook.dart';

class EpubService {
  const EpubService({
    this.maxCompressedBytes = 200 * 1024 * 1024,
    this.maxUncompressedBytes = 512 * 1024 * 1024,
    this.maxArchiveEntries = 10000,
  }) : assert(maxCompressedBytes > 0),
       assert(maxUncompressedBytes > 0),
       assert(maxArchiveEntries > 0);

  final int maxCompressedBytes;
  final int maxUncompressedBytes;
  final int maxArchiveEntries;

  Future<ReflowableBook> parseFile(String filePath) async {
    final compressedLimit = maxCompressedBytes;
    final uncompressedLimit = maxUncompressedBytes;
    final entryLimit = maxArchiveEntries;
    return Isolate.run(
      () => _parseFile(
        filePath,
        maxCompressedBytes: compressedLimit,
        maxUncompressedBytes: uncompressedLimit,
        maxArchiveEntries: entryLimit,
      ),
    );
  }

  static Future<ReflowableBook> _parseFile(
    String filePath, {
    required int maxCompressedBytes,
    required int maxUncompressedBytes,
    required int maxArchiveEntries,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) throw const EpubException('EPUB 文件不存在');

    try {
      final fileSize = await file.length();
      if (fileSize > maxCompressedBytes) {
        throw EpubException(
          'EPUB 文件过大（最大 ${_formatBytes(maxCompressedBytes)}）',
        );
      }
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      _validateArchiveLimits(
        archive,
        maxUncompressedBytes: maxUncompressedBytes,
        maxArchiveEntries: maxArchiveEntries,
      );
      final container = _findArchiveFile(archive, 'META-INF/container.xml');
      if (container == null) {
        throw const EpubException('无效的 EPUB：缺少 container.xml');
      }

      final containerDocument = XmlDocument.parse(_decode(container));
      final rootFile = _elements(containerDocument, 'rootfile').firstOrNull;
      final packagePath = rootFile?.getAttribute('full-path');
      if (packagePath == null || packagePath.isEmpty) {
        throw const EpubException('无效的 EPUB：找不到内容清单');
      }

      final packageFile = _findArchiveFile(archive, packagePath);
      if (packageFile == null) {
        throw const EpubException('无效的 EPUB：内容清单不存在');
      }

      final packageDocument = XmlDocument.parse(_decode(packageFile));
      final packageDirectory = path.posix.dirname(packagePath);
      final title =
          _firstText(packageDocument, 'title') ??
          path.basenameWithoutExtension(filePath);
      final author = _firstText(packageDocument, 'creator') ?? '未知作者';

      final manifest = <String, _ManifestItem>{};
      for (final item in _elements(packageDocument, 'item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        if (id == null || href == null) continue;
        manifest[id] = _ManifestItem(
          href: href,
          mediaType: item.getAttribute('media-type') ?? '',
          properties: (item.getAttribute('properties') ?? '')
              .split(RegExp(r'\s+'))
              .where((property) => property.isNotEmpty)
              .toSet(),
        );
      }

      final navigationTitles = _readNavigationTitles(
        archive,
        packageDirectory,
        manifest.values,
      );

      var readingOrder = <_ManifestItem>[];
      for (final itemReference in _elements(packageDocument, 'itemref')) {
        final id = itemReference.getAttribute('idref');
        final item = id == null ? null : manifest[id];
        if (item != null) readingOrder.add(item);
      }

      if (readingOrder.isEmpty) {
        readingOrder = manifest.values
            .where((item) => _isHtmlMediaType(item.mediaType, item.href))
            .toList();
      }

      final chapters = <ReflowableChapter>[];
      for (final item in readingOrder) {
        if (!_isHtmlMediaType(item.mediaType, item.href)) continue;
        final hrefPath = _hrefPath(item.href);
        final chapterPath = path.posix.normalize(
          path.posix.join(packageDirectory, hrefPath),
        );
        final chapterFile = _findArchiveFile(archive, chapterPath);
        if (chapterFile == null) continue;

        final document = html_parser.parse(_decode(chapterFile));
        final body = document.body;
        if (body == null) continue;

        final heading =
            body.querySelector('h1, h2, h3') ?? document.querySelector('title');
        final headingText = _cleanInlineText(heading?.text ?? '');
        final navigationTitle = navigationTitles[chapterPath];
        chapters.add(
          ReflowableChapter(
            title:
                navigationTitle ??
                (headingText.isEmpty
                    ? '第 ${chapters.length + 1} 章'
                    : headingText),
            html: body.innerHtml,
            order: chapters.length,
          ),
        );
      }

      if (chapters.isEmpty) {
        throw const EpubException('EPUB 中没有可阅读的章节');
      }

      return ReflowableBook(title: title, author: author, chapters: chapters);
    } on EpubException {
      rethrow;
    } on ArchiveException catch (error) {
      throw EpubException('无法解压 EPUB：$error');
    } on XmlParserException catch (error) {
      throw EpubException('EPUB 内容清单格式错误：$error');
    } on FormatException catch (error) {
      throw EpubException('EPUB 文件格式错误：$error');
    }
  }

  static void _validateArchiveLimits(
    Archive archive, {
    required int maxUncompressedBytes,
    required int maxArchiveEntries,
  }) {
    if (archive.files.length > maxArchiveEntries) {
      throw EpubException('EPUB 内文件数量过多（最大 $maxArchiveEntries 个）');
    }

    var uncompressedBytes = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      uncompressedBytes += entry.size;
      if (uncompressedBytes > maxUncompressedBytes) {
        throw EpubException(
          'EPUB 解压后内容过大（最大 ${_formatBytes(maxUncompressedBytes)}）',
        );
      }
    }
  }

  static Map<String, String> _readNavigationTitles(
    Archive archive,
    String packageDirectory,
    Iterable<_ManifestItem> manifestItems,
  ) {
    final titles = <String, String>{};

    for (final item in manifestItems.where(
      (item) => item.properties.contains('nav'),
    )) {
      try {
        final navigationPath = _resolveHref(packageDirectory, item.href);
        if (navigationPath == null) continue;
        final navigationFile = _findArchiveFile(archive, navigationPath);
        if (navigationFile == null) continue;
        final document = html_parser.parse(_decode(navigationFile));
        final navigationElements = document.querySelectorAll('nav');
        final tableOfContents = navigationElements.firstWhere(
          (element) =>
              element.attributes['epub:type'] == 'toc' ||
              element.attributes['role'] == 'doc-toc',
          orElse: () => navigationElements.first,
        );
        final navigationDirectory = path.posix.dirname(navigationPath);
        for (final anchor in tableOfContents.querySelectorAll('a[href]')) {
          final href = anchor.attributes['href'];
          final title = _cleanInlineText(anchor.text);
          final chapterPath = href == null
              ? null
              : _resolveHref(navigationDirectory, href);
          if (chapterPath != null && title.isNotEmpty) {
            titles.putIfAbsent(chapterPath, () => title);
          }
        }
      } on Object {
        // A broken optional navigation document should not make the book
        // unreadable; the chapter heading remains available as a fallback.
      }
    }

    for (final item in manifestItems.where(
      (item) =>
          item.mediaType == 'application/x-dtbncx+xml' ||
          path.posix.extension(_hrefPath(item.href)).toLowerCase() == '.ncx',
    )) {
      try {
        final navigationPath = _resolveHref(packageDirectory, item.href);
        if (navigationPath == null) continue;
        final navigationFile = _findArchiveFile(archive, navigationPath);
        if (navigationFile == null) continue;
        final document = XmlDocument.parse(_decode(navigationFile));
        final navigationMap = _elements(document, 'navMap').firstOrNull;
        if (navigationMap == null) continue;
        final navigationDirectory = path.posix.dirname(navigationPath);
        for (final point in _elements(navigationMap, 'navPoint')) {
          final label = _elements(point, 'navLabel').firstOrNull;
          final title = label == null ? null : _firstText(label, 'text');
          final href = _elements(
            point,
            'content',
          ).firstOrNull?.getAttribute('src');
          final chapterPath = href == null
              ? null
              : _resolveHref(navigationDirectory, href);
          if (chapterPath != null && title != null) {
            titles.putIfAbsent(chapterPath, () => _cleanInlineText(title));
          }
        }
      } on Object {
        // EPUB 2 navigation is optional for reading; retain heading fallback.
      }
    }

    return titles;
  }

  static String? _resolveHref(String baseDirectory, String href) {
    final hrefPath = _hrefPath(href);
    if (hrefPath.isEmpty) return null;
    return _normalizeArchivePath(path.posix.join(baseDirectory, hrefPath));
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).ceil()} KB';
    }
    return '${(bytes / (1024 * 1024)).ceil()} MB';
  }

  static Iterable<XmlElement> _elements(XmlNode node, String localName) {
    return node.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == localName,
    );
  }

  static String? _firstText(XmlNode node, String localName) {
    final value = _elements(node, localName).firstOrNull?.innerText.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static ArchiveFile? _findArchiveFile(Archive archive, String requestedPath) {
    final normalized = _normalizeArchivePath(requestedPath);
    for (final file in archive.files) {
      if (_normalizeArchivePath(file.name) == normalized) return file;
    }
    return null;
  }

  static String _normalizeArchivePath(String value) {
    final slashes = value.replaceAll('\\', '/');
    final withoutLeadingSlash = slashes.startsWith('/')
        ? slashes.substring(1)
        : slashes;
    return path.posix.normalize(withoutLeadingSlash);
  }

  static String _decode(ArchiveFile file) {
    final bytes = file.content as List<int>;
    return utf8.decode(bytes, allowMalformed: true).replaceAll('\uFEFF', '');
  }

  static String _hrefPath(String href) {
    try {
      return Uri.decodeComponent(Uri.parse(href).path);
    } on FormatException {
      return href.split('#').first;
    }
  }

  static bool _isHtmlMediaType(String mediaType, String href) {
    if (mediaType == 'application/xhtml+xml' || mediaType == 'text/html') {
      return true;
    }
    final extension = path.posix.extension(_hrefPath(href)).toLowerCase();
    return extension == '.xhtml' || extension == '.html' || extension == '.htm';
  }

  static String _cleanInlineText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

class EpubException implements Exception {
  const EpubException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ManifestItem {
  const _ManifestItem({
    required this.href,
    required this.mediaType,
    required this.properties,
  });

  final String href;
  final String mediaType;
  final Set<String> properties;
}
