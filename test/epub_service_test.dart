import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fluenca_reader/src/services/epub_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test('parses metadata and spine-ordered EPUB chapters', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'fluenca_epub_test_',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final epubFile = File(path.join(temporaryDirectory.path, 'sample.epub'));

    final archive = Archive()
      ..addFile(
        _textFile('META-INF/container.xml', '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
      )
      ..addFile(
        _textFile('OPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Café Stories</dc:title>
    <dc:creator>Zoë Author</dc:creator>
  </metadata>
  <manifest>
    <item id="chapter-two" href="chapter%202.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter-one" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="navigation" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
    <itemref idref="chapter-one"/>
    <itemref idref="chapter-two"/>
  </spine>
</package>'''),
      )
      ..addFile(
        _textFile(
          'OPS/nav.xhtml',
          '''<html xmlns:epub="http://www.idpf.org/2007/ops">
  <body>
    <nav epub:type="landmarks">
      <a href="chapter1.xhtml">Wrong landmark title</a>
    </nav>
    <nav epub:type="toc">
      <ol>
        <li><a href="chapter1.xhtml">The Beginning</a></li>
        <li><a href="chapter%202.xhtml#finale">The Ending</a></li>
      </ol>
    </nav>
  </body>
</html>''',
        ),
      )
      ..addFile(
        _textFile(
          'OPS/chapter1.xhtml',
          '<html><body><h1>Opening</h1><p>naïve résumé</p></body></html>',
        ),
      )
      ..addFile(
        _textFile(
          'OPS/chapter 2.xhtml',
          '<html><body><h2>Finale</h2><p>Second chapter.</p></body></html>',
        ),
      );
    await epubFile.writeAsBytes(ZipEncoder().encodeBytes(archive));

    final book = await const EpubService().parseFile(epubFile.path);

    expect(book.title, 'Café Stories');
    expect(book.author, 'Zoë Author');
    expect(book.chapters.map((chapter) => chapter.title), [
      'The Beginning',
      'The Ending',
    ]);
    expect(book.chapters.first.html, contains('naïve résumé'));
  });

  test('reports an invalid EPUB clearly', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'fluenca_epub_invalid_',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final epubFile = File(path.join(temporaryDirectory.path, 'invalid.epub'));
    await epubFile.writeAsBytes(ZipEncoder().encodeBytes(Archive()));

    expect(
      () => const EpubService().parseFile(epubFile.path),
      throwsA(isA<EpubException>()),
    );
  });

  test('parses EPUB 2 NCX chapter titles', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'fluenca_epub2_test_',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final epubFile = File(path.join(temporaryDirectory.path, 'epub2.epub'));

    final archive = Archive()
      ..addFile(
        _textFile('META-INF/container.xml', '''<container>
  <rootfiles><rootfile full-path="content.opf"/></rootfiles>
</container>'''),
      )
      ..addFile(
        _textFile('content.opf', '''<package>
  <metadata><title>EPUB 2 Book</title></metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="chapter"/></spine>
</package>'''),
      )
      ..addFile(
        _textFile('toc.ncx', '''<ncx><navMap><navPoint>
  <navLabel><text>NCX Chapter Name</text></navLabel>
  <content src="chapter.xhtml#start"/>
</navPoint></navMap></ncx>'''),
      )
      ..addFile(
        _textFile(
          'chapter.xhtml',
          '<html><body><p>Chapter without a heading.</p></body></html>',
        ),
      );
    await epubFile.writeAsBytes(ZipEncoder().encodeBytes(archive));

    final book = await const EpubService().parseFile(epubFile.path);

    expect(book.chapters.single.title, 'NCX Chapter Name');
  });

  test('rejects EPUB files that exceed configured resource limits', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'fluenca_epub_limit_',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final epubFile = File(path.join(temporaryDirectory.path, 'large.epub'));
    final archive = Archive()
      ..addFile(_textFile('large.txt', List.filled(2048, 'x').join()));
    await epubFile.writeAsBytes(ZipEncoder().encodeBytes(archive));

    expect(
      () => const EpubService(
        maxCompressedBytes: 1024 * 1024,
        maxUncompressedBytes: 1024,
      ).parseFile(epubFile.path),
      throwsA(isA<EpubException>()),
    );
  });
}

ArchiveFile _textFile(String name, String content) {
  return ArchiveFile.bytes(name, utf8.encode(content));
}
