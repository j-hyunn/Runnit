/// 카드 미리보기 + 공유 시트. **HI-10의 공통 종착점**이다 — 티어 승급·뱃지
/// 획득·PB 갱신 어느 지점에서 눌러도 여기로 온다.
///
/// ## 왜 미리보기를 거치는가 (바로 공유 시트를 열지 않고)
/// 캡처는 화면에 실제로 그려진 위젯만 구울 수 있다([captureCard] 문서 참조).
/// 미리보기 시트는 그 제약을 만족시키면서 동시에 **사용자가 무엇을 올리게 되는지
/// 보고 결정**하게 한다 — 내 GPS 경로가 그려진 이미지를 예고 없이 공유 시트에
/// 실어 보내는 건 프라이버시 측면에서도 나쁘다.
///
/// ## flutter-ui-designer에게
/// 이 파일은 **동작하는 골격**이다. 시트 프레임·버튼·상태 표시는 자유롭게 바꾸되
/// 아래 세 가지는 유지해야 캡처가 성립한다:
/// 1. 카드가 [ShareCardSurface]로 감싸여 화면에 실제로 올라가 있을 것
///    (`Offstage`/`Visibility(visible: false)` 금지 — 페인트를 건너뛴다).
/// 2. 같은 [GlobalKey]를 surface와 `shareCard(...)` 양쪽에 넘길 것.
/// 3. 캡처 중에는 버튼을 잠글 것 — 연타하면 8MB 이미지를 여러 장 동시에 굽는다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../data/share_providers.dart';
import '../data/share_service.dart';
import '../domain/share_card_data.dart';
import 'widgets/share_card_body.dart';
import 'widgets/share_card_surface.dart';

/// 카드 미리보기 시트를 띄운다. HI-10의 모든 공유 버튼이 이 함수를 부른다.
Future<void> showShareCardSheet(
  BuildContext context,
  ShareCardData card,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => ShareCardSheet(card: card),
  );
}

class ShareCardSheet extends ConsumerStatefulWidget {
  const ShareCardSheet({required this.card, super.key});

  final ShareCardData card;

  @override
  ConsumerState<ShareCardSheet> createState() => _ShareCardSheetState();
}

class _ShareCardSheetState extends ConsumerState<ShareCardSheet> {
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

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: ShareCardSurface(
                  boundaryKey: _boundaryKey,
                  child: ShareCardBody(card: widget.card),
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
            // 카드가 어떤 규격으로 나가는지 미리 알려 준다 — 인스타 스토리에
            // 올릴 때 잘리지 않는다는 신호(PRD HI-08 "9:16").
            Text(
              '인스타그램 스토리 규격(9:16)으로 저장돼요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
