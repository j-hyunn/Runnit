import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/api/supabase_client.dart';

/// 앱 진입점.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeSupabase();

  runApp(
    const ProviderScope(
      child: RunnitApp(),
    ),
  );
}
