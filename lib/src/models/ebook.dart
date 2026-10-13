import 'dart:io';

import 'package:path/path.dart' as path;

enum EbookType { epub, pdf, mobi }

class Ebook {
  const Ebook({required this.file, required this.type});

  final File file;
  final EbookType type;

  String get fileName => path.basename(file.path);
  String get displayName => path.basenameWithoutExtension(file.path);
}

class ReflowableChapter {
  const ReflowableChapter({
    required this.title,
    required this.html,
    required this.order,
  });

  final String title;
  final String html;
  final int order;
}

class ReflowableBook {
  const ReflowableBook({
    required this.title,
    required this.author,
    required this.chapters,
  });

  final String title;
  final String author;
  final List<ReflowableChapter> chapters;
}
