import 'package:freezed_annotation/freezed_annotation.dart';

part 'failure.freezed.dart';

/// 계층 경계를 넘는 에러 표현. repository는 예외를 던지는 대신
/// 이 타입으로 감싸거나, AsyncValue.error에 이 타입을 실어 보낸다.
@freezed
abstract class Failure with _$Failure {
  /// 네트워크/서버 통신 실패.
  const factory Failure.network({String? message, int? statusCode}) =
      NetworkFailure;

  /// 권한 거부 (위치, 건강 데이터 등).
  const factory Failure.permissionDenied({
    required String permission,
    @Default(false) bool permanentlyDenied,
  }) = PermissionDeniedFailure;

  /// 센서/위치 서비스 비활성.
  const factory Failure.serviceDisabled({required String service}) =
      ServiceDisabledFailure;

  /// 로컬 저장소 오류.
  const factory Failure.storage({String? message}) = StorageFailure;

  /// 인증 필요/만료.
  const factory Failure.unauthorized({String? message}) = UnauthorizedFailure;

  /// 그 외.
  const factory Failure.unknown({String? message, Object? cause}) =
      UnknownFailure;
}
