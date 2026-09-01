# A-3 — iPad 공유 시트 팝오버 앵커 수정 (QA A-6)

작성: flutter-ui-designer · 2026-09-01
대상: HI-09(GPX 내보내기) + HI-10(공유 카드)

## 문제

iPad에서 `Share.share*`는 팝오버로 뜨고, `sharePositionOrigin`이 팝오버 꼬리가 가리킬
사각형이 된다. 두 곳 모두 **페이지 `context`로 `findRenderObject()`** 를 불렀다:

```dart
final box = context.findRenderObject() as RenderBox?;   // ← 페이지 전체의 RenderBox
```

`RunDetailPage.build`/`_ShareCardPageState`의 `context`가 가리키는 렌더 오브젝트는
그 화면의 `Scaffold`다. 결과적으로 앵커가 `Offset.zero & 화면크기`가 되어, 팝오버가
누른 버튼이 아니라 화면 중앙 근처에서 뜬다. 크래시는 아니고 시각적 어긋남이지만,
화면이 큰 iPad일수록 "왜 여기서 뜨지"가 확실히 보인다.

HI-09 UI 메모는 "헤더 액션의 `RenderBox`에서 계산"이라고 적어 두었으나 코드는
그렇지 않았다 — 메모/코드 불일치도 함께 해소했다.

## 수정

### 1. 공통 헬퍼 신설 — `lib/core/utils/share_anchor.dart`

`Rect? shareOriginOfKey(GlobalKey key)` 하나뿐이다. **`BuildContext`가 아니라
`GlobalKey`만 받는다** — context를 받는 오버로드를 두면 호출부가 다시 페이지
context를 넘기는 같은 실수를 반복하게 된다. 키를 요구하면 "그 키를 어느 위젯에
달지"를 호출부가 반드시 결정하게 된다.

`attached`·`hasSize`를 모두 검사하고 못 구하면 null. null이어도 실패가 아니다 —
iPhone/Android는 앵커를 쓰지 않고, iPad도 OS 기본 위치로 떨어뜨린다.

### 2. `run_detail_page.dart` (HI-09)

- `_DetailActions`를 `StatelessWidget` → `StatefulWidget`으로 바꾸고 `_overflowKey`
  (`GlobalKey`)를 State가 소유한다. build에서 만들면 리빌드마다 새 키가 되어 앵커가
  헛돈다.
- `PopupMenuButton`에 그 키를 달고, `onSelected`에서 `shareOriginOfKey(_overflowKey)`로
  계산한 사각형을 콜백에 넘긴다.
- 콜백 시그니처 변경: `VoidCallback? onExportGpx` → `void Function(Rect? origin)?`.
- `exportRunAsGpx(...)`에 `{Rect? origin}` 파라미터 추가. 함수 내부의
  `context.findRenderObject()` 계산은 **삭제**했다 — 남겨 두면 다시 쓰이게 된다.
  "여기서 계산하면 안 되는 이유"를 함수 doc에 한 줄로 박아 두었다.

### 3. `share_card_sheet.dart` (HI-10) — 같은 패턴, 같이 수정

QA 지적 대상은 아니었지만 `_ShareCardPageState._share()`에 완전히 동일한 코드가
있었다(`context.findRenderObject()` = 공유 페이지 전체). `_shareButtonKey`를 State에
두고 `FilledButton.icon`에 달아 `shareOriginOfKey`로 교체했다.

`setState(_sharing = true)` 직후에 앵커를 계산하지만, setState는 dirty 표시만 하고
리빌드는 다음 프레임이라 이 시점의 렌더 트리는 아직 유효하다.

### 4. 손대지 않은 곳

- `app_shell.dart:73` — 이미 `_barKey.currentContext`로 키 기반 계산. 정상.
- `share_card_renderer.dart:83` — 캡처 경계(`boundaryKey`) 조회. 앵커와 무관.
- `notification_tile.dart:188` — 뷰포트 겹침 판정. 자기 자신의 박스를 쓰는 게 맞다.

## 테스트

`test/history/run_detail_page_test.dart` — `pump()`에 `size`·`gpxService` 인자 추가,
`_FakeGpxExportService`(origin만 기록) 신설, 케이스 1건 추가:

> `iPad 공유 앵커는 화면 전체가 아니라 오버플로 버튼 사각형이다`

iPad 12.9" 세로(1024×1366, DPR 1.0)에서 ⋮ → "GPX 내보내기"를 실제로 탭하고 넘어온
`origin`을 검증한다:

1. `Offset.zero & screen`(= 버그의 증상)과 같지 않다
2. 폭·높이가 각각 화면의 1/4 미만
3. `tester.getRect(⋮ 아이콘)`과 겹친다
4. 중심이 화면 오른쪽(dx > W/2) 위쪽(dy < H/4) — 헤더 액션 위치와 일치

1번만 있으면 "앵커가 null이어도 통과"하므로 2~4로 실제 버튼 위치까지 못 박았다.

## 검증

- `flutter analyze` — **No issues found!**
  (초기 실행 시 freezed/drift 생성 파일 부재로 567 error. `dart run build_runner build
  --delete-conflicting-outputs` 후 clean — 이 작업과 무관한 워크트리 초기 상태 문제)
- `flutter test` — **All tests passed (252건)**
- `flutter test test/history/run_detail_page_test.dart` — 16건 통과(신규 1건 포함)

## 디자인 토큰

변경 없음. 위젯 트리 구조(`StatelessWidget` → `StatefulWidget`)만 바뀌었고 렌더 결과는
동일하다.

## 남은 이슈

- **실기기 확인 여전히 필요.** 위젯 테스트는 `origin` 사각형이 올바른 값인지까지만
  본다. 그 값을 받은 UIKit 팝오버가 실제로 그 위치에 뜨는지는 iPad 실기기에서만
  확인된다. HI-09 메모 §남은 이슈의 `share_plus` MIME 타입 검증과 함께 묶어서 볼 것.
- **공유 카드(HI-10) 쪽은 위젯 테스트를 추가하지 않았다.** `share_card_sheet`의 공유
  경로는 `ShareService`(플랫폼 채널 + 캡처)를 타고, 이번 변경은 A-6과 동일한 1줄
  치환이라 회귀 위험이 낮다고 판단했다. 커버가 필요하면 `shareServiceProvider`를
  가짜로 갈아끼워 `run_detail_page_test`와 같은 방식으로 붙일 수 있다.
- 회전(landscape) 상태에서 앵커 좌표는 `localToGlobal`이 알아서 따라가므로 별도
  처리를 하지 않았다. 다만 팝오버가 떠 있는 동안 회전하면 OS가 앵커를 재조회하지
  않으므로 어긋난다 — iOS 공통 동작이고 앱에서 손댈 부분은 없다.
