import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/models/models.dart';

/// `RunRecord.clientReported`(마이그레이션 64 `runs.client_reported jsonb`)의
/// 직렬화 왕복과 표시용 파생값 계약.
///
/// 여기서 고정하는 것은 **flutter-ui가 상세 화면에서 소비할 인터페이스**다 —
/// 상세 화면은 `distanceWasAdjusted` 하나로 병기 여부를 정하고,
/// `clientReportedDistanceMeters` / `distanceAdjustmentMeters`로 숫자를 뽑는다.
void main() {
  RunRecord record({
    double distanceMeters = 9700,
    ClientReportedRun? clientReported,
  }) =>
      RunRecord(
        id: 'run-1',
        userId: 'user-1',
        startedAt: DateTime.utc(2026, 9, 7, 6),
        endedAt: DateTime.utc(2026, 9, 7, 7),
        activityType: ActivityType.outdoorRun,
        status: RunStatus.completed,
        distanceMeters: distanceMeters,
        elapsedSeconds: 3600,
        movingSeconds: 3500,
        clientReported: clientReported,
      );

  group('직렬화', () {
    test('서버 jsonb 모양 그대로 파싱하고 같은 모양으로 되돌린다', () {
      // 마이그레이션 64의 `jsonb_build_object` 키 4종.
      final json = <String, dynamic>{
        'distance_meters': 10000.0,
        'moving_seconds': 3600,
        'max_speed_mps': 5.2,
        'recalculated_at': '2026-09-07T06:00:00.000Z',
      };

      final parsed = ClientReportedRun.fromJson(json);
      expect(parsed.distanceMeters, 10000.0);
      expect(parsed.movingSeconds, 3600);
      expect(parsed.maxSpeedMps, 5.2);
      expect(parsed.recalculatedAt, DateTime.utc(2026, 9, 7, 6));

      // wire 키는 `client_reported` 하나로 유지된다 — 스칼라 2개로 펼쳤다면
      // `runs`에 없는 컬럼명이 업로드 payload에 섞였을 자리다.
      final round = RunRecord.fromJson(record(clientReported: parsed).toJson());
      expect(round.clientReported, parsed);
      expect(record(clientReported: parsed).toJson()['client_reported'], json);
    });

    test('PostgREST가 정수로 내려준 거리도 double로 받는다', () {
      // 10000.0이 jsonb에서 10000으로 돌아오는 경우. `as double` 캐스트였다면
      // 여기서 던지고 업로드 응답 채택 전체가 실패한다.
      final parsed = ClientReportedRun.fromJson(<String, dynamic>{
        'distance_meters': 10000,
        'moving_seconds': 3600,
      });
      expect(parsed.distanceMeters, 10000.0);
    });

    test('컬럼이 null이면 필드도 null이다', () {
      final round = RunRecord.fromJson(record().toJson());
      expect(round.clientReported, isNull);
    });
  });

  group('distanceWasAdjusted — 병기 판정', () {
    test('조정 기록이 없으면 false', () {
      expect(record().distanceWasAdjusted, isFalse);
      expect(record().clientReportedDistanceMeters, isNull);
      expect(record().distanceAdjustmentMeters, isNull);
    });

    test('10m를 넘게 깎였으면 true', () {
      final r = record(
        distanceMeters: 9700,
        clientReported: const ClientReportedRun(distanceMeters: 10000),
      );
      expect(r.distanceWasAdjusted, isTrue);
      expect(r.clientReportedDistanceMeters, 10000);
      expect(r.distanceAdjustmentMeters, 300);
    });

    test('임계 이하의 미세 조정은 병기하지 않는다', () {
      // 서버는 1m 차이부터 client_reported를 남긴다. 그것까지 배너로 띄우면
      // 상시 노출이 되어 정말 깎인 기록의 신호를 덮는다.
      final r = record(
        distanceMeters: 9995,
        clientReported: const ClientReportedRun(distanceMeters: 10000),
      );
      expect(r.distanceWasAdjusted, isFalse);
      expect(r.clientReportedDistanceMeters, isNull);
    });

    test('정확히 임계값이면 병기하지 않는다 (초과일 때만)', () {
      final r = record(
        distanceMeters: 9990,
        clientReported: const ClientReportedRun(distanceMeters: 10000),
      );
      expect(r.distanceWasAdjusted, isFalse);
    });

    test('확정 거리가 더 크면 병기하지 않는다', () {
      // 서버는 `least(recalc, claimed)`이라 이 상태가 나오지 않지만, 나오더라도
      // "기기보다 더 뛴 것으로 확정"을 사용자에게 보여줄 이유는 없다.
      final r = record(
        distanceMeters: 10000,
        clientReported: const ClientReportedRun(distanceMeters: 9700),
      );
      expect(r.distanceWasAdjusted, isFalse);
    });

    test('client_reported는 있는데 거리가 비었으면 false', () {
      final r = record(
        clientReported: const ClientReportedRun(movingSeconds: 3600),
      );
      expect(r.distanceWasAdjusted, isFalse);
    });
  });
}
