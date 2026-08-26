/// 카드 미리보기 + 공유 페이지. **HI-10의 공통 종착점**이다 — 티어 승급·뱃지
/// 획득·PB 갱신 어느 지점에서 눌러도 여기로 온다.
///
/// ## 왜 미리보기를 거치는가 (바로 공유 시트를 열지 않고)
/// 캡처는 화면에 실제로 그려진 위젯만 구울 수 있다([captureCard] 문서 참조).
/// 미리보기는 그 제약을 만족시키면서 동시에 **사용자가 무엇을 올리게 되는지
/// 보고 결정**하게 한다 — 내 GPS 경로가 그려진 이미지를 예고 없이 공유 시트에
/// 실어 보내는 건 프라이버시 측면에서도 나쁘다.
///
/// 2026-08-26: 바텀시트에서 **풀페이지**로 전환했다(사용자 요청) — 카드가
/// 세로로 긴 9:16 규격이라 시트로 접으면 실제 크기를 가늠하기 어려웠다.
///
/// 2026-08-26(2): 카드가 **투명 오버레이 스티커**로 바뀌면서 미리보기도
/// 다시 잡았다. **체커보드 바탕**을 카드 뒤에 깐다 — 배경이 없다는 사실을
/// 말로만 설명하면 사용자는 "왜 카드가 반투명해 보이지?"로 읽는다. 체커는
/// 캡처 경계([ShareCardSurface]) **바깥**에 있어 PNG에 구워지지 않는다.
///
/// 2026-08-26(3): 사용자가 준 정확한 레퍼런스 이미지가 9:16 세로였다 —
/// (2)에서 가로 16:9로 바꾼 건 되돌리고, 폭 제약을 다시 세로 카드에 맞는
/// 값으로 좁혔다.
///
/// ## flutter-ui-designer에게
/// 이 파일은 **동작하는 골격**이다. 페이지 프레임·버튼·상태 표시는 자유롭게
/// 바꾸되 아래 세 가지는 유지해야 캡처가 성립한다:
/// 1. 카드가 [ShareCardSurface]로 감싸여 화면에 실제로 올라가 있을 것
///    (`Offstage`/`Visibility(visible: false)` 금지 — 페인트를 건너뛴다).
/// 2. 같은 [GlobalKey]를 surface와 `shareCard(...)` 양쪽에 넘길 것.
/// 3. 캡처 중에는 버튼을 잠글 것 — 연타하면 8MB 이미지를 여러 장 동시에 굽는다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../data/share_card_renderer.dart';
import '../data/share_providers.dart';
import '../data/share_service.dart';
import '../domain/share_card_data.dart';
import 'widgets/share_card_body.dart';
import 'widgets/share_card_surface.dart';

/// 카드 미리보기 페이지를 연다. HI-10의 모든 공유 버튼이 이 함수를 부른다.
///
/// 이름은 과거 바텀시트 시절 그대로 유지한다 — 호출부 4곳이 이 시그니처만
/// 알면 되고, `Future<void>`로 "닫히면 끝"이라는 계약은 페이지 전환에서도
/// 동일하다.
///
/// **`rootNavigator: true`가 핵심이다.** 호출부는 전부 `AppShell`의 탭별
/// 중첩 Navigator(`StatefulShellRoute.indexedStack`의 `homeKey`/`trackingKey`
/// 등) 안에 있다. 여기서 `Navigator.of(context)`(루트 지정 없이)를 쓰면
/// 그 중첩 Navigator에 push되어, 결국 `AppShell`의 `Scaffold`(플로팅 알약
/// 하단 네비바 포함) **안에서** 렌더링된다 — 풀페이지로 바꾼 의미가 없어지고
/// 네비바가 카드 위에 계속 떠 있게 된다(2026-08-26 확인된 회귀). 셸 바깥
/// 루트 Navigator로 push해야 `login` 라우트처럼 네비바 없는 진짜 전체 화면이
/// 된다.
Future<void> showShareCardSheet(
  BuildContext context,
  ShareCardData card,
) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ShareCardPage(card: card),
    ),
  );
}

class ShareCardPage extends ConsumerStatefulWidget {
  const ShareCardPage({required this.card, super.key});

  final ShareCardData card;

  @override
  ConsumerState<ShareCardPage> createState() => _ShareCardPageState();
}

class _ShareCardPageState extends ConsumerState<ShareCardPage> {
  /// 캡처 대상 경계. State가 소유해야 리빌드 사이에 안정적으로 같은 위젯을 가리킨다.
  final _boundaryKey = GlobalKey();

  bool _sharing = false;
  String? _error;

  /// 메달 SVG 디코드가 끝났는지. 끝나기 전에는 공유 버튼을 잠근다 —
  /// 캡처는 프레임 하나만 기다리므로, 데우기 전에 구우면 **메달 자리가 빈 카드**가
  /// 인스타로 나간다. 앱 밖으로 나간 이미지는 회수할 수 없어서 여기서 막는다.
  bool _artReady = false;

  @override
  void initState() {
    super.initState();
    _warmUpArt();
  }

  Future<void> _warmUpArt() async {
    await precacheShareCardArt(widget.card);
    if (mounted) setState(() => _artReady = true);
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });

    // iPad는 팝오버 앵커가 없으면 시트를 띄우지 못한다. 시트 자체의 위치를 준다.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    final outcome = await ref.read(shareServiceProvider).shareCard(
          boundaryKey: _boundaryKey,
          card: widget.card,
          origin: origin,
        );

    if (!mounted) return;
    setState(() {
      _sharing = false;
      // "공유 완료"라고 말하지 않는다 — OS는 게시 여부를 알려주지 않는다
      // (`ShareOutcome` 문서 참조). 실패했을 때만 말한다.
      _error = outcome == ShareOutcome.failed ? '공유할 이미지를 만들지 못했어요.' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '닫기',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('공유하기'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.s20),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    // 세로 9:16 카드라 폭이 좁아야 화면 안에 온전히 들어온다.
                    // 태블릿에서 무한정 커지지 않게 상한도 겸한다.
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: AspectRatio(
                      aspectRatio: shareCardAspectRatio,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // ⚠️ 캡처 경계 밖이다 — 체커는 PNG에 찍히지 않는다.
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(AppTokens.rLg),
                            child: CustomPaint(
                              painter: _TransparencyChecker(
                                light: theme.colorScheme.surfaceContainerHighest,
                                dark: theme.colorScheme.surfaceContainerHigh,
                              ),
                            ),
                          ),
                          ShareCardSurface(
                            boundaryKey: _boundaryKey,
                            child: ShareCardBody(card: widget.card),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.s16),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
                const SizedBox(height: AppTokens.s8),
              ],
              FilledButton.icon(
                // 캡처 중 잠금(연타하면 8MB 이미지를 여러 장 동시에 굽는다) +
                // 아트 준비 전 잠금.
                onPressed: (_sharing || !_artReady) ? null : _share,
                icon: _sharing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share),
                label: Text(_sharing ? '이미지 만드는 중…' : '공유하기'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppTokens.minTapTarget),
                ),
              ),
              const SizedBox(height: AppTokens.s8),
              // 무엇이 저장되는지 미리 알려 준다. "배경 없는 스티커"라는 점을
              // 말해 주지 않으면 사용자는 이걸 그대로 올리려다 실망한다.
              Text(
                '배경이 없는 9:16 스티커로 저장돼요. 스토리에 올린 사진 위에 얹어 보세요.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 미리보기 뒤에 깔리는 체커보드. "이 카드에는 배경이 없다"를 그림으로
/// 말한다 — 이미지 편집기의 투명 표시와 같은 관습이라 설명이 필요 없다.
///
/// **캡처 경계 밖에서만 쓴다.** 안으로 들어가면 체커가 그대로 PNG에 구워진다.
class _TransparencyChecker extends CustomPainter {
  const _TransparencyChecker({required this.light, required this.dark});

  final Color light;
  final Color dark;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = light);
    final paint = Paint()..color = dark;
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        if ((x + y).isEven) continue;
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TransparencyChecker oldDelegate) =>
      oldDelegate.light != light || oldDelegate.dark != dark;
}
