import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/auth/auth_providers.dart';
import '../../../../core/notifications/push_permission.dart';
import '../../../../core/notifications/push_token_sync.dart';
import '../../../../core/theme/app_tokens.dart';

/// OS 알림 권한 프라이밍 — **첫 러닝 완료 직후** 요약 화면에서만 뜬다.
///
/// ## 왜 첫 실행이 아닌가 (architect §1.3)
/// 첫 실행 다이얼로그는 거부율이 높고, **한 번 거부되면 앱이 되돌릴 수 없다**
/// (시스템 설정으로 보내는 것 외엔 방법이 없다). 성취 직후는 수락률이 가장
/// 높고, 그 시점의 사용자는 "다음 알림이 왜 필요한지"를 이미 안다 — 방금
/// 기록한 거리가 티어·순위로 이어지는 것을 본 직후이기 때문이다.
///
/// ## 과하지 않게
/// - [PushPermissionStatus.notDetermined]에서만 뜬다. 이미 승인·거부했으면
///   다시 묻지 않는다.
/// - "나중에"를 누르면 [_dismissedKey]가 남아 **두 번 다시 뜨지 않는다.**
///   러닝마다 같은 카드를 보여주는 것은 설득이 아니라 소음이다.
/// - FCM 미설정 빌드([PushPermissionStatus.unavailable])에서는 뜨지 않는다.
class NotificationPermissionPrimer extends ConsumerStatefulWidget {
  const NotificationPermissionPrimer({super.key});

  @override
  ConsumerState<NotificationPermissionPrimer> createState() =>
      _NotificationPermissionPrimerState();
}

class _NotificationPermissionPrimerState
    extends ConsumerState<NotificationPermissionPrimer> {
  static const _dismissedKey = 'runnit.push.primer_dismissed';

  bool? _dismissed;
  var _requesting = false;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    var dismissed = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      dismissed = prefs.getBool(_dismissedKey) ?? false;
    } catch (_) {
      // 저장소 실패는 "아직 안 눌렀다"로 본다 — 프라이밍을 못 보는 것보다
      // 한 번 더 보는 쪽이 낫다.
    }
    if (mounted) setState(() => _dismissed = dismissed);
  }

  Future<void> _setDismissed() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_dismissedKey, true);
    } catch (_) {
      // 실패해도 이번 화면에서는 사라진다.
    }
  }

  Future<void> _request() async {
    setState(() => _requesting = true);
    final status = await requestPushPermission(ref);
    if (status.isGranted) {
      // 승인 직후 토큰을 등록한다. 이 호출이 없으면 다음 로그인까지 토큰이
      // 서버에 올라가지 않아, 권한은 있는데 푸시는 안 오는 상태가 된다.
      await ref.read(pushTokenSyncProvider).registerNow();
    }
    await _setDismissed();
    if (mounted) setState(() => _requesting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed != false) return const SizedBox.shrink();
    if (!ref.watch(isAuthenticatedProvider)) return const SizedBox.shrink();

    final status = ref.watch(pushPermissionStatusProvider).valueOrNull;
    if (status != PushPermissionStatus.notDetermined) {
      return const SizedBox.shrink();
    }

    return Container(
      // 숨겨질 때 빈 여백을 남기지 않도록 아래 간격을 카드가 직접 갖는다.
      margin: const EdgeInsets.only(bottom: AppTokens.s16),
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: const Color(0xFFF2FBF5),
        borderRadius: BorderRadius.circular(AppTokens.rLg),
        border: Border.all(color: const Color(0xFFCBEBD6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '다음 러닝, 무엇이 걸려 있는지 알려드릴까요?',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: AppTokens.s8),
          const Text(
            '다음 티어까지 남은 거리, 이번 주 순위 변동, 새로 얻은 뱃지를 '
            '알림으로 보내드려요. 종류별로 언제든 끌 수 있어요.',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Color(0xFF3D6B4C),
            ),
          ),
          const SizedBox(height: AppTokens.s16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _requesting ? null : _request,
                  child: _requesting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('알림 받기'),
                ),
              ),
              const SizedBox(width: AppTokens.s8),
              TextButton(
                onPressed: _requesting ? null : _setDismissed,
                child: const Text('나중에'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
