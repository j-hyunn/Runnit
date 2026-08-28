# QA — 지도 SDK 교체(flutter_map/OSM → flutter_naver_map) 경계 정합성 검증

| 항목 | 내용 |
|------|------|
| 일자 | 2026-08-28 |
| 범위 | **경계 정합성만** (전체 회귀 아님). 검증 항목 6개 |
| 검증자 | qa-integration-tester |
| 기준 | `docs/PRD.md` §7 (지도 SDK = Naver Map), `docs/ARCHITECTURE.md` v0.4, `docs/TRD.md` v0.11 |
| 결과 | **PASS 6 / CONFIRMED 결함 4 (High 1, Medium 1, Low 2) / 미검증 2** |

> 심각: **DEF-1 — 지도 초기화 실패가 앱 전체를 죽인다.** 코드에 적힌 계약("초기화 실패로 앱을 죽이지 않는다")이 실제로 강제되지 않는다.

---

## 1. 검증 항목별 결과

| # | 항목 | 결과 |
|---|------|------|
| 1 | `flutter_map`/`osm_attribution`/`mapTileProviderOverride`/`OsmAttribution` 잔존 참조 | ⚠️ 코드 참조 0건. 주석 1건 잔존(DEF-4) |
| 2 | latlong2 `LatLng` 내부 표준 유지 / `NLatLng` 누출 없음 | ✅ PASS |
| 3 | `liveRouteProvider` · `runRoutePointsProvider` 타입 ↔ 지도 위젯 소비부 | ✅ PASS |
| 4 | 문서(ARCHITECTURE/TRD/PRD) ↔ 코드 정합 | ⚠️ 대부분 일치. 누락 2건(DEF-2, DEF-3) |
| 5 | `flutter analyze` / `flutter test` | ✅ PASS (analyze: No issues found / test: 175 tests, All tests passed) |
| 6 | 네이티브(INTERNET·minSdk) | ✅ PASS |

---

## 2. CONFIRMED 결함

### DEF-1 [High] 지도 SDK 초기화 실패가 `runApp` 이전에 앱을 죽인다 — 주석에 적힌 계약과 코드 불일치

- `lib/core/map/naver_map_config.dart:26-31` 주석: *"앱의 나머지 기능(트래킹·기록·랭킹)은 지도와 무관하게 동작해야 하므로 **초기화 실패로 앱을 죽이지 않는다**"*
- 실제 코드 `lib/core/map/naver_map_config.dart:43` — `await FlutterNaverMap().init(...)`에 예외 처리가 없다.
- `lib/main.dart:14` — `await initializeNaverMap();`가 `runApp()` **앞**에 있고 역시 try/catch가 없다.
- 플러그인 구현(`flutter_naver_map-1.4.4/lib/src/initializer/flutter_naver_map_initializer.dart:40`)은 `NChannel.sdkChannel.invokeMethod("initializeNcp", ...)`를 await한다. 네이티브 등록 실패·플랫폼 예외(`MissingPluginException` / `PlatformException`) 시 **throw**한다.
- `onAuthFailed`는 **인증 실패 콜백일 뿐** 초기화 예외를 잡지 못한다(플러그인 `_handler`가 `onAuthFailed` 메서드 콜만 처리).
- 결과: 지도 네이티브 초기화가 실패하면 `main()`이 예외로 종료되어 **흰 화면 / 즉시 종료**. 트래킹·기록·랭킹까지 전부 못 쓴다. 주석이 약속한 격리가 실제로는 없다.

**수정 요청** (`lib/core/map/naver_map_config.dart:34-55`)

```dart
Future<void> initializeNaverMap() async {
  ...
  try {
    await FlutterNaverMap().init(clientId: ..., onAuthFailed: ...);
  } catch (e, st) {
    // 지도 초기화 실패는 앱 기동을 막지 않는다 — 지도만 비어 보인다.
    debugPrint('[NaverMap] 초기화 실패(앱은 계속 기동): $e\n$st');
  }
}
```

담당: mobile-architect (또는 이번 교체 작업자)

---

### DEF-2 [Medium] 하네스 스킬·에이전트 문서 3곳이 여전히 `flutter_map`을 권고한다

PRD §7과 ARCHITECTURE v0.4 / TRD v0.11은 `flutter_naver_map`으로 정리됐으나, 실제 작업 지시를 담은 하네스 문서는 갱신되지 않았다. 다음 UI/구조 작업에서 `flutter_map`으로 되돌아갈 위험이 있다(CLAUDE.md 규칙 2·3 위반: 하네스가 PRD와 불일치).

- `.claude/skills/flutter-ui-patterns/SKILL.md:37` — `` `flutter_map`: open source, no API key needed, shows the route via a polyline layer ``
- `.claude/skills/flutter-architecture-setup/SKILL.md:98` — `| Map | `flutter_map` (open source, no cost) or `google_maps_flutter` … |`
- `.claude/agents/flutter-ui-designer.md:34` — `Route visualization with a map widget (flutter_map or google_maps_flutter)`

**수정 요청**: 세 곳을 `flutter_naver_map` + `core/map/map_surface.dart`(표면 주입점) / `core/map/map_geo.dart`(좌표 변환 경계) 기준으로 갱신하고, `docs/HARNESS.md` 변경 이력에 기록. (하네스 파일은 영어로 유지)

---

### DEF-3 [Low] `ARCHITECTURE.md` §3.1 파일 트리에 `core/map/`이 없다

`docs/ARCHITECTURE.md:103` — `config/  error/  providers/  theme/  utils/  widgets/` 로만 나열되어 신규 디렉터리 `lib/core/map/`(map_geo.dart / map_surface.dart / naver_map_config.dart)가 빠져 있다. 같은 문서 §2·§12는 갱신됐으므로 트리만 누락된 상태.

부수 사항: `docs/HARNESS.md:40`의 변경 파일 목록도 `lib/core/map/*`, `lib/main.dart`, `test/tracking/tracking_page_test.dart`, `test/history/run_detail_page_test.dart`를 빠뜨렸다.

**수정 요청**: §3.1 트리에 아래 한 줄 추가(`repositories/` 위)

```
    map/                    # 지도 SDK 경계 — map_geo(LatLng↔NLatLng) / map_surface(주입점·스타일) / naver_map_config(초기화)
```

---

### DEF-4 [Low] `mapTileProviderOverride` 문자열이 주석에 잔존 — 검증항목 1의 "grep 0건" 미충족

`lib/core/map/map_surface.dart:12` — `(기존 \`mapTileProviderOverride\`가 하던 역할을 이 주입점이 대신한다.)`

코드 참조가 아니라 교체 히스토리를 설명하는 주석이므로 **동작 위험은 없다.** 다만 지시한 grep 조건(잔존 0건)은 충족하지 못한다. 삭제된 심볼명을 코드에 남길지는 판단 사항 — 유지한다면 검증 기준을 "코드 참조 0건"으로 조정할 것.

---

## 3. PASS 상세 (근거)

### 항목 1 — 잔존 참조
`grep -rn "flutter_map\|osm_attribution\|mapTileProviderOverride\|OsmAttribution\|OSM" lib test` → **코드 참조 0건**, 주석 1건(DEF-4).
`lib/core/widgets/osm_attribution.dart` 삭제 확인(`git status: D`). `pubspec.yaml`에서 `flutter_map` 제거, `pubspec.lock`에도 `flutter_map` 항목 없음(=`pub get` 반영됨). `latlong2 ^0.9.1` 유지.

### 항목 2 — 좌표 모델 경계
`grep -rn "NLatLng" lib test` 결과 전부 `lib/core/map/map_geo.dart`(7건) 내부. 지도 위젯 2개(`run_map_view.dart`, `run_route_map.dart`)는 `NCameraPosition`/`NMarker`/`NPolylineOverlay` 등 SDK 오버레이 타입만 다루고, 좌표는 `.toNaver()` / `.toNaverCoords()` / `.toNaverBounds()` 확장으로만 변환한다 — 원시 `NLatLng` 생성 없음.

`git diff --stat`로 아래 파일 **무변경** 확인:
- `lib/features/sharing/**` (share_card_builder 포함)
- `lib/features/tracking/domain/polyline_codec.dart`
- `lib/features/tracking/domain/run_session_aggregator.dart`
- `lib/features/tracking/presentation/tracking_ui_providers.dart`
- `lib/features/history/presentation/run_detail_providers.dart` — ※ 실제 경로는 `lib/features/history/data/run_detail_providers.dart`이며 이 파일도 무변경

### 항목 3 — provider 타입 ↔ 소비부
| provider | 선언 | 타입 | 소비부 | 일치 |
|---|---|---|---|---|
| `liveRouteProvider` | `tracking_ui_providers.dart:66` | `NotifierProvider<LiveRoute, List<LatLng>>` | `run_map_view.dart:53` `ref.read(...).lastOrNull`, `:76` `ref.listen<List<LatLng>>`, `:174` `.select((route) => route.isNotEmpty)` | ✅ |
| `runRoutePointsProvider` | `history/data/run_detail_providers.dart:38` | `Provider.autoDispose.family<List<LatLng>, String>` | `run_detail_page.dart:89` → `:135` `RunRouteMap(route: route)` (`route.length >= 2` 가드 후) | ✅ |

`RunRouteMap.route`는 `List<LatLng>`(latlong2) — provider 반환형과 동일. `RunMapUnavailable`(`run_map_view.dart:207`) 폴백 경로도 유지.

빈 경로 안전성 확인: `run_route_map.dart:53`의 `late final _options`가 `widget.route.first`를 읽지만, `late` 지연 평가라 `build()`의 `route.length < 2` 가드(`:65`) 통과 뒤 `:73`에서 처음 접근된다 → 빈 리스트로도 throw 없음.

### 항목 4 — 문서 정합
- `docs/ARCHITECTURE.md`: 버전 v0.4 ✅ / §12-#2 `~~2~~ … 해소(2026-08-28)` 표기 ✅ / §2 다이어그램 `OSM["OSM 타일 서버"]` → `Naver["Naver Map SDK\n(flutter_naver_map)"]` 교체 및 엣지 `App -->|"지도 타일·인증(NCP)"| Naver` ✅ / §2 하단 서술 "PRD §7과 일치" ✅ / §13 말미 "지도 SDK 불일치(§12-#2)는 착수 전 사용자 확인 대상." 문구 삭제 ✅ / 근거 문서 PRD v1.5 ✅
- `docs/TRD.md`: 버전 v0.11 ✅ / 근거 문서 ARCHITECTURE v0.4 ✅ / §2 확정 스택 지도 행이 `flutter_naver_map` + latlong2(내부 좌표 모델)로 교체되고 `map_geo`·`map_surface`·`run_route_map` 명시 ✅
- `docs/PRD.md`: **무변경** 확인(`git diff --stat docs/PRD.md` 빈 결과). §7 line 455 `| 지도 | **Naver Map** (flutter_naver_map) |`, §부록 line 592 그대로 ✅
- v0.10/v0.3 변경 이력에 남은 `flutter_map` 언급은 **히스토리 기록**이므로 정상.

### 항목 5 — 정적 분석·테스트
- `flutter analyze` → `No issues found! (ran in 2.6s)`
- `flutter test` → `00:08 +175: All tests passed!`
- 테스트 전환 방식 확인: 두 테스트 모두 `mapTileProviderOverride.overrideWithValue(_StubTileProvider())` → `mapSurfaceBuilderProvider.overrideWithValue(stubMapSurfaceBuilder)`로 교체하고 `_StubTileProvider` 클래스·`dart:convert`/`dart:typed_data` import 제거. `stubMapSurfaceBuilder`는 `onMapReady`를 호출하지 않으므로 `_onMapReady` 경로(마커 굽기·카메라 fit)는 테스트가 타지 않는다 — `map_surface.dart:36-37` 주석에 그 계약이 명시돼 있고, 두 위젯 모두 컨트롤러 없이도 화면이 성립한다(`run_map_view.dart:102` null 가드). 위젯 존재 검증(`find.byType(RunRouteMap)` / `RunMapView` / `RunMapUnavailable`)은 그대로 유효.

### 항목 6 — 네이티브
- `android/app/src/main/AndroidManifest.xml:7` — `INTERNET`이 **main**에 존재 ✅ (기존에는 debug/profile에만 있었음. 릴리즈 빌드에서 지도 타일·Supabase가 전부 막히던 함정 해소). `:8` `ACCESS_NETWORK_STATE`도 추가 ✅
- `android/app/build.gradle.kts:25` — `minSdk = maxOf(flutter.minSdkVersion, 23)` ✅ (플러그인 `android/build.gradle`의 `minSdkVersion 23` 요구와 일치)
- 네이버 Maven 저장소는 플러그인이 `rootProject.allprojects { repositories { maven { url 'https://repository.map.naver.com/archive/maven' } } }`로 주입한다. 앱 `android/settings.gradle.kts`에 `dependencyResolutionManagement`(`FAIL_ON_PROJECT_REPOS`) 블록이 없으므로 앱 측 추가 설정 불필요 ✅
- Client ID 이중 선언 없음: AndroidManifest에 `meta-data` 없음, `AppDelegate.swift`는 주석만 추가(코드 변경 0), `Info.plist`에 `NMFClientId` 없음 ✅ — 1.3.1+ NCP 신인증 경로와 일치
- iOS 배포 타깃 `IPHONEOS_DEPLOYMENT_TARGET = 15.0` (요구 12.0 이상) ✅

---

## 4. 미검증 / 알려진 리스크 (결함 아님)

| # | 내용 |
|---|------|
| U-1 | **NCP Client ID가 플레이스홀더**(`naver_map_config.dart:22` `'YOUR_NAVER_MAP_CLIENT_ID'`). 실기기에서 지도는 인증 실패로 회색. 문서(TRD v0.11 이력)에도 명시돼 있으며 배포 전 교체 필요 — 의도된 상태이므로 결함으로 잡지 않음 |
| U-2 | **실제 네이티브 빌드 미수행**(`flutter build apk` / `pod install`). Gradle 병합·AGP 9.1.0 ↔ 플러그인 AGP 8.11.1, CocoaPods 의존성 해결은 이번 검증 범위 밖. 실기기 검증 시 최초 1회 확인 필요 |
| U-3 | 지도 렌더링·카메라 이동·폴리라인 증분 갱신의 **런타임 동작**은 위젯 테스트가 스텁 표면을 쓰므로 커버되지 않는다(설계상 의도). 실기기 트래킹 스모크 테스트 별도 필요 |
