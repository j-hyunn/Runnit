import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// Supabase 클라이언트 초기화/접근 지점.
///
/// 계약:
/// - 초기화는 `AppConfig.supabaseUrl` / `AppConfig.supabaseAnonKey` 사용
///   (키를 소스에 하드코딩하지 않는다 — `--dart-define-from-file` 로 주입)
/// - `main()`의 `runApp` 이전에 [initializeSupabase] 호출
/// - Postgres 컬럼명은 snake_case, Dart 모델은 camelCase.
///   변환은 모델의 `@JsonSerializable(fieldRename: FieldRename.snake)`가
///   전담하므로 쿼리 계층에서 수동 매핑을 하지 않는다.

/// `main()`에서 `runApp` 이전에 정확히 한 번 호출한다.
Future<void> initializeSupabase() async {
  if (!AppConfig.isConfigured) {
    throw StateError(
      'SUPABASE_URL / SUPABASE_ANON_KEY 가 설정되지 않았습니다. '
      '--dart-define-from-file=env/dev.json 로 실행하세요.',
    );
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );
}

/// 리포지토리 구현체가 공통으로 주입받는 접근점.
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});
