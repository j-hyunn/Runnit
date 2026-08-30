import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:firebase_messaging/firebase_messaging.dart';

import 'app.dart';
import 'core/api/supabase_client.dart';
import 'core/map/naver_map_config.dart';
import 'core/notifications/firebase_bootstrap.dart';
import 'core/notifications/push_messaging.dart';

/// 앱 진입점.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeSupabase();
  // 네이버 지도는 첫 `NaverMap` 위젯보다 먼저 초기화돼 있어야 한다
  // (`NaverMap.build()`가 `assert(isInitialized)`로 시작한다).
  //
  // `initializeNaverMap()`이 이미 자체 try/catch를 갖고 있지만, 여기서도 한 번 더
  // 막는다 — 지도 초기화가 `runApp()`을 막아 앱 전체를 못 띄우는 일은 어떤
  // 경로로도 일어나면 안 된다. 지도만 회색이 되고 나머지는 그대로 동작한다.
  try {
    await initializeNaverMap();
  } catch (error) {
    debugPrint('[main] 지도 초기화를 건너뜁니다: $error');
  }

  // FCM(PRD §5.10). 설정 파일이 없으면 `isFirebaseAvailable`이 false로 남고
  // 푸시 경로만 조용히 꺼진다 — 알림함·알림 설정 화면은 그대로 동작한다.
  await initializeFirebase();
  if (isFirebaseAvailable) {
    // 백그라운드 핸들러는 `runApp` 전에 등록해야 한다. 등록하지 않으면 일부
    // Android 기기에서 data-only 메시지가 조용히 버려진다.
    FirebaseMessaging.onBackgroundMessage(runnitFirebaseBackgroundHandler);
  }

  runApp(
    const ProviderScope(
      child: RunnitApp(),
    ),
  );
}
