import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/ebook.dart';

class EbookLibraryService {
  EbookLibraryService({Directory? libraryDirectory})
    : _libraryDirectory = libraryDirectory;

  static const supportedExtensions = <String>{'.epub', '.pdf', '.mobi'};
  static const libraryFolderName = 'ebooks';

  final Directory? _libraryDirectory;

  static EbookType? typeForPath(String filePath) {
    return switch (path.extension(filePath).toLowerCase()) {
      '.epub' => EbookType.epub,
      '.pdf' => EbookType.pdf,
      '.mobi' => EbookType.mobi,
      _ => null,
    };
  }

  Future<Directory> getLibraryDirectory() async {
    if (_libraryDirectory != null) {
      await _libraryDirectory.create(recursive: true);
      return _libraryDirectory;
    }

    final documentsDirectory = await getApplicationDocumentsDirectory();
    final directory = Directory(
      path.join(documentsDirectory.path, libraryFolderName),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<Ebook>> loadBooks() async {
    final directory = await getLibraryDirectory();
    final books = <Ebook>[];

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final type = typeForPath(entity.path);
      if (type != null) books.add(Ebook(file: entity, type: type));
    }

    books.sort(
      (a, b) => a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()),
    );
    return books;
  }

  Future<Ebook> importFile(File source, {String? preferredName}) async {
    final type = typeForPath(preferredName ?? source.path);
    if (type == null) {
      throw const FormatException('仅支持 EPUB、PDF 和 MOBI 文件');
    }
    if (!await source.exists()) {
      throw FileSystemException('文件不存在', source.path);
    }

    final directory = await getLibraryDirectory();
    final sourceName = path.basename(preferredName ?? source.path);
    final safeName = _sanitizeFileName(sourceName);
    final destination = await _availableDestination(directory, safeName);

    if (path.equals(
      path.absolute(source.path),
      path.absolute(destination.path),
    )) {
      return Ebook(file: source, type: type);
    }

    await source.copy(destination.path);
    return Ebook(file: destination, type: type);
  }

  Future<void> deleteBook(Ebook book) async {
    if (await book.file.exists()) await book.file.delete();
  }

  String _sanitizeFileName(String fileName) {
    final sanitized = fileName.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    if (sanitized.isEmpty) return '未命名电子书.epub';
    return sanitized;
  }

  Future<File> _availableDestination(
    Directory directory,
    String fileName,
  ) async {
    final extension = path.extension(fileName);
    final baseName = path.basenameWithoutExtension(fileName);
    var candidate = File(path.join(directory.path, fileName));
    var copyNumber = 2;

    while (await candidate.exists()) {
      candidate = File(
        path.join(directory.path, '$baseName ($copyNumber)$extension'),
      );
      copyNumber++;
    }
    return candidate;
  }
}
