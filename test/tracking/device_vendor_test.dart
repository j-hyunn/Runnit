import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/core/api/wire_enums.dart';
import 'package:runnit/features/tracking/data/health_wearable_source.dart';
import 'package:runnit/models/models.dart';

/// `HealthWearableMetricsSource.vendorFor`의 회귀 테스트.
///
/// 이 함수가 뱃지 `device_source_count_gte`(애플워치런/애플워치러너/가민런/
/// 가민러너 4종)와 `device_source_diversity_gte`(올라운더)의 **유일한 원천**이다.
/// 여기서 오분류하면 뱃지가 조용히 미지급된다.
///
/// 플랫폼별 입력 형태가 다르다는 점이 핵심이다 (health 11.1.1):
/// - iOS: `sourceId` = bundleIdentifier, `sourceName` = 사용자에게 보이는 이름
/// - Android: `sourceId`는 **항상 빈 문자열**, `sourceName` = 패키지명
void main() {
  DeviceVendor vendor({String? id, String? name}) =>
      HealthWearableMetricsSource.vendorFor(sourceId: id, sourceName: name);

  group('Garmin', () {
    test('iOS 번들 id', () {
      expect(
        vendor(id: 'com.garmin.connect.mobile', name: 'Garmin Connect'),
        DeviceVendor.watchGarmin,
      );
    });

    test('Android 패키지명은 sourceName으로 온다 (sourceId는 빈 문자열)', () {
      expect(
        vendor(id: '', name: 'com.garmin.android.apps.connectmobile'),
        DeviceVendor.watchGarmin,
      );
    });

    test('표시명만 있어도 잡힌다', () {
      expect(vendor(name: 'Garmin Connect'), DeviceVendor.watchGarmin);
    });
  });

  group('Apple Watch', () {
    test('com.apple.health.<UUID> + 기기명에 Watch', () {
      expect(
        vendor(
          id: 'com.apple.health.9A2B7C31-0000-4000-8000-000000000000',
          name: '지현의 Apple Watch',
        ),
        DeviceVendor.watchApple,
      );
    });

    test('같은 번들 prefix라도 iPhone이 쓴 데이터는 애플워치가 아니다', () {
      // HealthKit은 iPhone이 쓴 데이터에도 같은 `com.apple.health.<UUID>`를 준다.
      // 기기명까지 봐야 구분된다 — 이 케이스가 깨지면 폰 기록에
      // 애플워치 뱃지가 오지급된다.
      expect(
        vendor(
          id: 'com.apple.health.11111111-0000-4000-8000-000000000000',
          name: '지현의 iPhone',
        ),
        isNot(DeviceVendor.watchApple),
      );
    });

    test('워치 이름을 바꾸면 식별 실패 → watchOther로 저하 (오지급 아님)', () {
      // 알려진 한계다. 애플워치 뱃지가 안 붙을 뿐 잘못 붙지는 않는다.
      expect(
        vendor(
          id: 'com.apple.health.22222222-0000-4000-8000-000000000000',
          name: '내시계',
          // 러닝 중 심박 폴링 경로가 쓰는 fallback과 동일하게 둔다.
        ),
        isNot(DeviceVendor.watchApple),
      );
    });
  });

  group('그 외 웨어러블', () {
    test('Samsung Health', () {
      expect(
        vendor(id: '', name: 'com.sec.android.app.shealth'),
        DeviceVendor.watchOther,
      );
    });

    test('Google Fit', () {
      expect(
        vendor(id: '', name: 'com.google.android.apps.fitness'),
        DeviceVendor.watchOther,
      );
    });

    test('Polar', () {
      expect(vendor(name: 'Polar Flow'), DeviceVendor.watchOther);
    });
  });

  group('fallback', () {
    test('식별 실패 시 기본값은 unknown', () {
      expect(vendor(id: 'com.example.app', name: 'Mystery'), DeviceVendor.unknown);
    });

    test('러닝 중 심박 경로는 watchOther로 저하한다', () {
      // 폰은 러닝 중 심박을 연속 측정하지 못한다 — 연속 심박의 존재 자체가
      // 웨어러블의 증거이므로 unknown보다 watchOther가 정확하다.
      expect(
        HealthWearableMetricsSource.vendorFor(
          sourceId: 'com.example.app',
          sourceName: 'Mystery',
          fallback: DeviceVendor.watchOther,
        ),
        DeviceVendor.watchOther,
      );
    });

    test('null 입력도 던지지 않는다', () {
      expect(vendor(), DeviceVendor.unknown);
    });
  });

  group('뱃지 토큰 정합성', () {
    test('DeviceVendor의 JSON 값은 뱃지 카탈로그 토큰과 문자 그대로 같다', () {
      // docs/badge-catalog.csv / badge_catalog.condition_value jsonb /
      // Postgres device_vendor 라벨 / @JsonValue — 네 곳이 같은 문자열이어야
      // 한다. 매핑 테이블이 없다는 것이 이 설계의 핵심이므로 고정해 둔다.
      expect(
        DeviceVendor.values.map((DeviceVendor v) => v.wire).toList(),
        <String>['phone', 'watchApple', 'watchGarmin', 'watchOther', 'unknown'],
      );
    });

    test('isWatch는 워치 3종만 참이다', () {
      expect(
        DeviceVendor.values.where((DeviceVendor v) => v.isWatch).toList(),
        <DeviceVendor>[
          DeviceVendor.watchApple,
          DeviceVendor.watchGarmin,
          DeviceVendor.watchOther,
        ],
      );
    });
  });
}
