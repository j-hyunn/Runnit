import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'push_device_token.freezed.dart';
part 'push_device_token.g.dart';

/// FCM 등록 토큰 1건 (PRD §5.10 발송 전제). DB 테이블은 `push_tokens`.
///
/// ## 키는 [token]이고, 유저당 여러 행이 정상이다
/// 한 사람이 폰 + 태블릿, 또는 기기 교체 전후로 여러 토큰을 가진다.
/// `user_id`를 PK로 잡으면 두 번째 기기가 첫 번째를 밀어내고, 사용자는
/// "폰에서는 알림이 오는데 다른 폰에서는 안 온다"를 겪는다.
///
/// ## 토큰은 언제든 무효가 된다
/// FCM 토큰은 앱 재설치·데이터 삭제·장기 미사용으로 조용히 만료된다. 발송 시
/// `UNREGISTERED`/`INVALID_ARGUMENT`가 오면 **서버가 그 행을 지운다** — 이것이
/// 유일한 정리 경로다. 클라이언트는 지워진 사실을 알 수 없고, 다음 실행에서
/// 새 토큰을 upsert하면 자연히 복구된다.
///
/// ## 로그아웃 시 반드시 지운다
/// 남겨두면 기기를 넘겨받은 다음 사용자에게 이전 사용자의 순위·티어 알림이
/// 간다. 로그아웃은 `deleteToken(token)` 한 번으로 끝나야 하며, 실패해도
/// 로그아웃 자체를 막지 않는다(다음 로그인 시 다른 user_id로 덮어쓰인다).
@freezed
abstract class PushDeviceToken with _$PushDeviceToken {
  const PushDeviceToken._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PushDeviceToken({
    /// FCM 등록 토큰. **PK**.
    required String token,

    required String userId,

    required DevicePlatform platform,

    /// 기기 식별자(설치 단위, `installations` id 또는 앱이 생성해 저장한 UUID).
    /// 토큰이 회전해도 유지되므로, 같은 기기의 옛 토큰을 정리하는 근거가 된다.
    /// 얻지 못하면 null — 그 경우 정리는 발송 실패에만 의존한다.
    String? deviceId,

    /// 진단용. "특정 버전에서만 알림이 안 온다"를 추적할 유일한 단서다.
    String? appVersion,

    /// 마지막 upsert 시각(UTC). 서버가 채운다.
    /// 오래된 토큰(예: 270일 무갱신)을 배치로 정리할 때의 기준.
    DateTime? updatedAt,
  }) = _PushDeviceToken;

  factory PushDeviceToken.fromJson(Map<String, dynamic> json) =>
      _$PushDeviceTokenFromJson(json);
}
