import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../error/failure.dart';

/// Supabase/Postgrest 예외를 계층 경계 타입인 [Failure]로 변환한다.
///
/// UI는 `AsyncValue.error`에 실려온 값을 그대로 보여주지 않고 종류로 분기하므로,
/// 리포지토리 밖으로는 SDK 예외 타입이 새어나가지 않게 여기서 전부 감싼다.
Failure mapSupabaseError(Object error) {
  if (error is Failure) return error;

  if (error is AuthException) {
    return Failure.unauthorized(message: error.message);
  }

  if (error is PostgrestException) {
    final status = int.tryParse(error.code ?? '');
    // 42501 = insufficient_privilege (RLS 거부), PGRST301 = JWT 만료/누락.
    if (error.code == '42501' || error.code == 'PGRST301' || status == 401) {
      return Failure.unauthorized(message: error.message);
    }
    return Failure.network(message: error.message, statusCode: status);
  }

  if (error is StorageException) {
    return Failure.network(message: error.message);
  }

  if (error is TimeoutException) {
    return const Failure.network(message: '요청 시간이 초과되었습니다.');
  }

  return Failure.unknown(message: error.toString(), cause: error);
}

/// 리포지토리 메서드 본문을 감싸 예외를 [Failure]로 정규화한다.
Future<T> guardSupabase<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(mapSupabaseError(error), stackTrace);
  }
}
