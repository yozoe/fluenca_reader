import 'package:flutter/material.dart';

import 'screens/library_screen.dart';

class FluencaReaderApp extends StatelessWidget {
  const FluencaReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF52684B);
    return MaterialApp(
      title: 'Fluenca Reader',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light, seedColor),
      darkTheme: _theme(Brightness.dark, seedColor),
      home: const LibraryScreen(),
    );
  }

  ThemeData _theme(Brightness brightness, Color seedColor) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      appBarTheme: const AppBarTheme(centerTitle: false),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }
}
