import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/sync/run_sync_coordinator.dart';
import 'core/theme/app_theme.dart';

class RunnitApp extends ConsumerWidget {
  const RunnitApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // 한 번 읽어서 앱 수명 동안 계속 살아있게 한다 — 실패한 러닝 업로드
    // 재시도(로그인/앱 복귀/2분 주기)를 백그라운드에서 담당한다.
    ref.watch(runSyncCoordinatorProvider);
    return MaterialApp.router(
      title: 'Runnit',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
