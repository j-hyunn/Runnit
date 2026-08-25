import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_tokens.dart';
import '../data/tracking_providers.dart';

/// 웨어러블 연동 화면 — "러닝 설정" 바텀시트의 웨어러블 섹션에서 진입한다.
///
/// 연동 여부는 [wearableConnectionProvider]로 판단한다(대기 화면에서도
/// 조회 가능한 1회성 값 — `GeolocatorRunTrackingService.wearableConnected`는
/// 진행 중 세션에서만 의미가 있어 여기 쓸 수 없다). 연동된 기기가 있으면
/// 그 기기 이름을 보여주고, 없으면 권한을 요청하는 "연동하기" 버튼을 보여준다.
class WearableConnectPage extends ConsumerWidget {
  const WearableConnectPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(wearableConnectionProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        child: Column(
          children: [
            _Header(onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: connection.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => _ConnectBody(
                  connected: false,
                  deviceName: null,
                  onConnect: () => _connect(context, ref),
                ),
                data: (deviceName) => _ConnectBody(
                  connected: deviceName != null,
                  deviceName: deviceName,
                  onConnect: () => _connect(context, ref),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    final source = ref.read(wearableMetricsSourceProvider);
    final authorized = await source.ensureAuthorized();
    ref.invalidate(wearableConnectionProvider);
    // 재조회가 끝날 때까지 기다렸다가, 그래도 기기를 못 찾았으면 안내한다.
    final deviceName = await ref.read(wearableConnectionProvider.future);
    if (!context.mounted) return;
    if (!authorized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('권한 요청이 거부됐거나 이 기기에서는 지원하지 않아요.')),
      );
    } else if (deviceName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('권한은 확인됐지만 아직 연동된 기기 데이터가 없어요. 워치로 기록을 남긴 뒤 다시 확인해 주세요.'),
        ),
      );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Row(
        children: [
          InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(AppTokens.rPill),
            child: SvgPicture.asset(
              'assets/icons/chevron_right.svg',
              width: 24,
              height: 24,
              colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
            ).let((child) => Transform.flip(flipX: true, child: child)),
          ),
          const SizedBox(width: 16),
          const Text(
            '웨어러블 연동',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
          ),
        ],
      ),
    );
  }
}

class _ConnectBody extends StatelessWidget {
  const _ConnectBody({
    required this.connected,
    required this.deviceName,
    required this.onConnect,
  });

  final bool connected;
  final String? deviceName;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTokens.s24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected ? const Color(0x1A00C84B) : const Color(0xFFF3F3F3),
                ),
                child: Icon(
                  connected ? Icons.watch : Icons.watch_outlined,
                  size: 34,
                  color: connected ? const Color(0xFF00C84B) : const Color(0xFF9B9B9B),
                ),
              ),
              const SizedBox(height: AppTokens.s20),
              Text(
                connected ? '$deviceName 연동됨' : '연동된 웨어러블이 없어요',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black),
              ),
              const SizedBox(height: AppTokens.s8),
              Text(
                connected
                    ? '이 기기의 심박수 데이터가 러닝 기록에 함께 저장돼요.'
                    : 'Apple Watch는 건강 앱, Garmin은 Garmin Connect를 통해 자동으로 연결돼요. '
                        '연동하려면 아래 버튼으로 건강 데이터 접근 권한을 허용해 주세요.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF616161), height: 1.4),
              ),
              const SizedBox(height: AppTokens.s24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onConnect,
                  style: FilledButton.styleFrom(
                    backgroundColor: connected ? const Color(0xFFF3F3F3) : const Color(0xFF00C84B),
                    foregroundColor: connected ? Colors.black : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: AppTokens.s16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTokens.rPill),
                    ),
                  ),
                  child: Text(connected ? '다시 확인' : '연동하기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _WidgetLet on Widget {
  Widget let(Widget Function(Widget) f) => f(this);
}
