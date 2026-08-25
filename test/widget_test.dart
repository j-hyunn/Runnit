import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:runnit/app.dart';

void main() {
  // RunnitApp -> go_router redirect -> authStateProvider -> supabaseClientProvider
  // 이 Supabase.instance.client 를 동기적으로 읽으므로, 초기화 없이 pumpWidget 하면
  // "You must initialize the supabase instance" 로 즉시 깨진다. 실제 네트워크 호출
  // 없이(익명 초기 세션만 구성) 로컬로만 초기화한다.
  //
  // supabase_flutter 는 세션을 shared_preferences 에 저장하는데, 위젯 테스트
  // 환경에는 그 플랫폼 채널 구현이 없어 목 초기값을 먼저 심어줘야 한다.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test.supabase.co',
      publishableKey: 'test-anon-key',
    );
  });

  testWidgets('RunnitApp builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: RunnitApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RunnitApp), findsOneWidget);
  });
}
