import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/error/failure.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/models.dart';
import '../../home/presentation/widgets/ranking_widgets.dart';
import '../data/avatar_service.dart';
import 'widgets/profile_scaffold.dart';

/// AC-02 프로필 편집 — 표시이름 · 사진 · 체중 · 주간 목표.
///
/// ## 편집 대상이 이 넷뿐인 이유
/// - `username`(고유 핸들)은 **고정**이다(브리핑 확정). 랭킹·뱃지·공유 카드가
///   이 값을 사람 식별자로 쓰고 있어서 바꾸면 "어제 본 그 사람"을 못 찾는다.
///   화면에는 읽기 전용으로 보여준다 — 편집 화면에 아예 없으면 "왜 못 바꾸지"가
///   아니라 "어디서 바꾸지"가 되어 더 헷갈린다.
/// - `heightCm` / `birthDate` / `gender`는 PRD §5.8 AC-02의 편집 항목이 아니다.
///   모델에는 있지만 이 화면은 손대지 않는다 — `updateProfile`이 이 셋을
///   `user` 객체의 현재 값 그대로 다시 보내므로 값이 지워지지 않는다.
///
/// ## 검증은 서버 CHECK와 같은 범위로 건다
/// `weight_kg`는 20~400(마이그레이션 기존 CHECK), `weekly_goal_km`는 0 초과
/// 500 이하(마이그레이션 53)다. 클라이언트에서 같은 범위를 걸어 서버 400을
/// 미리 막되, **서버가 최종 판정자**라는 전제는 유지한다 — 저장 실패는 항상
/// 화면에 표시된다.
class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _displayName = TextEditingController();
  final _weight = TextEditingController();
  final _weeklyGoal = TextEditingController();

  /// 컨트롤러 초기화는 프로필이 처음 도착한 **한 번만** 한다. 매 빌드마다 하면
  /// 사용자가 입력하는 도중 provider가 갱신될 때 타이핑이 되돌려진다.
  bool _seeded = false;

  PickedAvatar? _pickedAvatar;

  /// 사용자가 "사진 삭제"를 눌렀는지. `_pickedAvatar`와 상호배타다.
  bool _avatarCleared = false;

  bool _saving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _displayName.dispose();
    _weight.dispose();
    _weeklyGoal.dispose();
    super.dispose();
  }

  void _seed(AppUser profile) {
    if (_seeded) return;
    _seeded = true;
    _displayName.text = profile.displayName ?? '';
    _weight.text = _numberText(profile.weightKg);
    _weeklyGoal.text = _numberText(profile.weeklyGoalKm);
  }

  /// `70.0` → `70`, `32.5` → `32.5`. 정수인데 소수점이 붙어 있으면 사용자가
  /// 자기가 입력한 적 없는 값을 보게 된다.
  static String _numberText(double? value) {
    if (value == null) return '';
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toString();
  }

  Future<void> _pickAvatar() async {
    setState(() => _errorMessage = null);
    try {
      final picked = await ref.read(avatarPickerProvider).pickFromGallery();
      if (picked == null || !mounted) return;

      final ext = AvatarPolicy.extensionOf(picked.fileName);
      if (ext == null || !AvatarPolicy.mimeByExtension.containsKey(ext)) {
        setState(() => _errorMessage = 'JPG · PNG · WebP 이미지만 올릴 수 있어요.');
        return;
      }
      if (picked.byteLength > AvatarPolicy.maxBytes) {
        // 피커가 이미 512px로 줄이므로 실제로는 거의 도달하지 않지만, 원본이
        // 극단적으로 큰 경우(파노라마 등)를 대비해 남겨 둔다. 서버가 거절하는
        // 것보다 여기서 이유를 말해주는 편이 낫다.
        setState(() => _errorMessage = '이미지 용량이 2MB를 넘어요. 다른 사진을 선택해 주세요.');
        return;
      }

      setState(() {
        _pickedAvatar = picked;
        _avatarCleared = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '사진을 불러오지 못했어요. 권한을 확인해 주세요.');
    }
  }

  Future<void> _save(AppUser profile) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _saving = true;
      _errorMessage = null;
    });

    final previousAvatarUrl = profile.avatarUrl;
    String? uploadedUrl;

    try {
      // 1) 새 사진이 있으면 먼저 올린다. **프로필 갱신보다 먼저** 해야 한다 —
      //    반대로 하면 URL 없는 프로필이 잠깐 저장된 상태가 생긴다.
      var avatarUrl = profile.avatarUrl;
      if (_avatarCleared) {
        avatarUrl = null;
      } else if (_pickedAvatar != null) {
        uploadedUrl =
            await ref.read(avatarStorageProvider).upload(profile.id, _pickedAvatar!);
        avatarUrl = uploadedUrl;
      }

      final displayName = _displayName.text.trim();
      final updated = profile.copyWith(
        // 빈 문자열은 저장하지 않는다 — `AppUser.label`이 username으로 폴백하는
        // 조건이 `displayName == null`이라, ''를 넣으면 라벨이 빈칸이 된다.
        displayName: displayName.isEmpty ? null : displayName,
        avatarUrl: avatarUrl,
        weightKg: _parseOptionalNumber(_weight.text),
        weeklyGoalKm: _parseOptionalNumber(_weeklyGoal.text),
      );

      await ref.read(userRepositoryProvider).updateProfile(updated);

      // 2) 프로필이 새 URL을 가리킨 뒤에야 이전 파일을 지운다. 순서가 반대면
      //    저장이 실패했을 때 옛 사진까지 잃는다.
      if (previousAvatarUrl != null && previousAvatarUrl != avatarUrl) {
        await ref.read(avatarStorageProvider).removeByPublicUrl(previousAvatarUrl);
      }

      ref.invalidate(currentProfileProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('프로필을 저장했어요')));
      Navigator.of(context).pop();
    } catch (error) {
      // 업로드는 됐는데 프로필 갱신이 실패한 경우, 방금 올린 파일은 아무도
      // 가리키지 않는 고아가 된다 — 여기서 되돌린다.
      if (uploadedUrl != null) {
        await ref.read(avatarStorageProvider).removeByPublicUrl(uploadedUrl);
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage = _messageOf(error);
      });
    }
  }

  static double? _parseOptionalNumber(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  static String _messageOf(Object error) {
    if (error is Failure) {
      return error.when(
        network: (message, statusCode) =>
            '저장하지 못했어요. 네트워크 상태를 확인해 주세요.'
            '${statusCode == null ? '' : ' ($statusCode)'}',
        permissionDenied: (permission, _) => '권한이 없어요($permission).',
        serviceDisabled: (service) => '$service 서비스를 사용할 수 없어요.',
        storage: (message) => message ?? '사진을 저장하지 못했어요.',
        unauthorized: (_) => '로그인이 만료됐어요. 다시 로그인해 주세요.',
        unknown: (message, _) => '저장하지 못했어요. 잠시 후 다시 시도해 주세요.',
      );
    }
    return '저장하지 못했어요. 잠시 후 다시 시도해 주세요.';
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(currentProfileProvider);

    return ProfileScaffold(
      title: '프로필 편집',
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _LoadError(
          onRetry: () => ref.invalidate(currentProfileProvider),
        ),
        data: (profile) {
          if (profile == null) {
            return _LoadError(
              onRetry: () => ref.invalidate(currentProfileProvider),
            );
          }
          _seed(profile);
          return _Form(
            formKey: _formKey,
            profile: profile,
            displayName: _displayName,
            weight: _weight,
            weeklyGoal: _weeklyGoal,
            pickedBytes: _pickedAvatar?.bytes,
            avatarCleared: _avatarCleared,
            saving: _saving,
            errorMessage: _errorMessage,
            onPickAvatar: _saving ? null : _pickAvatar,
            onClearAvatar: _saving
                ? null
                : () => setState(() {
                      _avatarCleared = true;
                      _pickedAvatar = null;
                    }),
            onSave: _saving ? null : () => _save(profile),
          );
        },
      ),
    );
  }
}

class _Form extends StatelessWidget {
  const _Form({
    required this.formKey,
    required this.profile,
    required this.displayName,
    required this.weight,
    required this.weeklyGoal,
    required this.pickedBytes,
    required this.avatarCleared,
    required this.saving,
    required this.errorMessage,
    required this.onPickAvatar,
    required this.onClearAvatar,
    required this.onSave,
  });

  final GlobalKey<FormState> formKey;
  final AppUser profile;
  final TextEditingController displayName;
  final TextEditingController weight;
  final TextEditingController weeklyGoal;
  final Uint8List? pickedBytes;
  final bool avatarCleared;
  final bool saving;
  final String? errorMessage;
  final VoidCallback? onPickAvatar;
  final VoidCallback? onClearAvatar;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final currentUrl = avatarCleared ? null : profile.avatarUrl;
    final hasPhoto = pickedBytes != null || (currentUrl?.isNotEmpty ?? false);

    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.s16,
          0,
          AppTokens.s16,
          AppTokens.s32,
        ),
        children: [
          Center(
            child: Column(
              children: [
                ProfileCircle(
                  size: 96,
                  imageUrl: currentUrl,
                  imageBytes: pickedBytes,
                ),
                const SizedBox(height: AppTokens.s12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: onPickAvatar,
                      child: const Text('사진 변경'),
                    ),
                    if (hasPhoto)
                      TextButton(
                        onPressed: onClearAvatar,
                        child: const Text('사진 삭제'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.s8),
          _FieldCard(
            children: [
              _ReadOnlyRow(label: '아이디', value: profile.username),
              const _FieldDivider(),
              _FieldRow(
                label: '표시 이름',
                child: TextFormField(
                  controller: displayName,
                  enabled: !saving,
                  maxLength: 20,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    hintText: '비워두면 아이디가 표시돼요',
                    border: InputBorder.none,
                    isDense: true,
                    counterText: '',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s16),
          _FieldCard(
            children: [
              _FieldRow(
                label: '체중 (kg)',
                child: TextFormField(
                  controller: weight,
                  enabled: !saving,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [_decimalFormatter],
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    hintText: '미입력',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  // 칼로리 추정에만 쓰이는 값이라 **필수가 아니다** — 빈 값을
                  // 강제하면 사진만 바꾸려는 사용자가 체중을 입력해야 저장된다.
                  validator: (value) => _rangeValidator(
                    value,
                    min: 20,
                    max: 400,
                    unit: 'kg',
                  ),
                ),
              ),
              const _FieldDivider(),
              _FieldRow(
                label: '주간 목표 (km)',
                child: TextFormField(
                  controller: weeklyGoal,
                  enabled: !saving,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [_decimalFormatter],
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: '미설정',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  validator: (value) => _rangeValidator(
                    value,
                    // 서버 CHECK가 `> 0`이라 0은 "목표 없음"이 아니라 오류다.
                    // 목표를 지우고 싶으면 빈 값으로 둔다.
                    min: 0.1,
                    max: 500,
                    unit: 'km',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.s4),
            child: Text(
              '주간 목표는 표시 전용이에요. 티어·랭킹·뱃지 판정에는 영향을 주지 않아요.',
              style: TextStyle(fontSize: 12, color: Color(0xFF9B9B9B)),
            ),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: AppTokens.s16),
            _ErrorBanner(message: errorMessage!),
          ],
          const SizedBox(height: AppTokens.s24),
          SizedBox(
            height: AppTokens.minTapTarget,
            child: FilledButton(
              onPressed: onSave,
              child: saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('저장'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 소수점 하나까지만 허용. `,`나 두 번째 `.`가 들어가면 `double.tryParse`가
/// null을 내고, 그게 validator에서 "숫자를 입력해 주세요"로 보이는데 사용자는
/// 자기가 뭘 잘못 쳤는지 모른다 — 애초에 못 치게 막는다.
final _decimalFormatter =
    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'));

String? _rangeValidator(
  String? value, {
  required double min,
  required double max,
  required String unit,
}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null; // 미입력 허용(= null 저장)
  final parsed = double.tryParse(text);
  if (parsed == null) return '숫자를 입력해 주세요';
  if (parsed < min || parsed > max) {
    return '${_trim(min)}~${_trim(max)}$unit 범위로 입력해 주세요';
  }
  return null;
}

String _trim(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

class _FieldCard extends StatelessWidget {
  const _FieldCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2.5),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s16),
      child: Column(children: children),
    );
  }
}

class _FieldDivider extends StatelessWidget {
  const _FieldDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, color: Color(0xFFEAEAEA));
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF616161),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return _FieldRow(
      label: label,
      child: Row(
        children: [
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, color: Color(0xFF9B9B9B)),
            ),
          ),
          const Icon(Icons.lock_outline, size: 16, color: Color(0xFF9B9B9B)),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppTokens.rMd),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: AppTokens.s8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 14, color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('프로필을 불러오지 못했어요'),
          const SizedBox(height: AppTokens.s12),
          OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    );
  }
}
