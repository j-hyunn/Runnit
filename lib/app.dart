import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/notifications/push_messaging.dart';
import 'core/notifications/push_token_sync.dart';
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
    // 푸시 수신·딥링크와 토큰 라이프사이클도 앱 수명에 매단다. 화면이
    // 소유하면 알림 화면에 한 번도 안 들어간 사용자는 토큰이 등록되지 않아
    // 푸시를 영영 못 받는다(ARCHITECTURE §7.5.3).
    ref.watch(pushMessagingProvider);
    ref.watch(pushTokenSyncProvider);
    return MaterialApp.router(
      title: 'Runnit',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
