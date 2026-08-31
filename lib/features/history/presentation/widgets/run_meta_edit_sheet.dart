import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/repository_providers.dart';
import '../../../../core/repositories/run_repository.dart';
import '../../../../core/theme/app_tokens.dart';

/// 러닝 상세(HI-07)의 **제목·메모 편집** 바텀시트를 띄운다.
///
/// 저장에 성공하면 서버가 확정한 [RunMeta]를, 취소하면 `null`을 반환한다.
/// 호출부는 반환값이 있을 때만 상세 provider를 무효화하면 된다.
Future<RunMeta?> showRunMetaEditSheet(
  BuildContext context, {
  required String runId,
  String? initialTitle,
  String? initialNote,
}) {
  return showModalBottomSheet<RunMeta>(
    context: context,
    useRootNavigator: true,
    // 키보드가 올라오면 시트 자체가 밀려 올라가야 메모 입력란이 가려지지 않는다.
    isScrollControlled: true,
    barrierColor: const Color(0x99000000),
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => _RunMetaEditSheet(
      runId: runId,
      initialTitle: initialTitle,
      initialNote: initialNote,
    ),
  );
}

/// ## 왜 삭제 버튼이 없는가
/// PRD v1.6 §8.1 — 사용자는 러닝을 삭제할 수 없다. 서버에도 삭제 정책이 없어서
/// (마이그레이션 51-3) 버튼을 두면 로컬 행만 지워지고 다음 원격 조회에서 기록이
/// 되살아난다. "수정만 가능"은 화면에서도 그대로 보여야 한다.
///
/// ## 왜 실패를 스낵바가 아니라 시트 안에 표시하는가
/// 이 시트는 모달이라 뒤의 `Scaffold`에 띄운 스낵바가 배리어에 가린다. 게다가
/// 실패 시 시트를 닫아야 스낵바가 보이는데, 그러면 사용자가 방금 쓴 메모가 함께
/// 사라진다. 그래서 실패는 **시트를 열어 둔 채** 인라인으로 알리고 재시도하게 한다.
/// 성공 스낵바만 시트가 닫힌 뒤 호출부가 띄운다.
class _RunMetaEditSheet extends ConsumerStatefulWidget {
  const _RunMetaEditSheet({
    required this.runId,
    this.initialTitle,
    this.initialNote,
  });

  final String runId;
  final String? initialTitle;
  final String? initialNote;

  @override
  ConsumerState<_RunMetaEditSheet> createState() => _RunMetaEditSheetState();
}

class _RunMetaEditSheetState extends ConsumerState<_RunMetaEditSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.initialTitle ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.initialNote ?? '');

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final meta = await ref.read(runRepositoryProvider).updateMeta(
            widget.runId,
            title: _title.text,
            note: _note.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop(meta);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        // 실패 원인을 그대로 노출하지 않는다 — 사용자가 할 수 있는 일은
        // 네트워크를 확인하고 다시 누르는 것뿐이다.
        _error = '저장하지 못했어요. 네트워크를 확인하고 다시 시도해 주세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 키보드 높이만큼 시트를 밀어 올린다.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.s24,
            AppTokens.s24,
            AppTokens.s24,
            AppTokens.s24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '기록 수정',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: AppTokens.s4),
              const Text(
                '제목과 메모만 고칠 수 있어요. 거리·시간 기록은 바꿀 수 없어요.',
                style: TextStyle(fontSize: 13, color: Color(0xFF616161)),
              ),
              const SizedBox(height: AppTokens.s24),
              _Field(
                label: '제목',
                controller: _title,
                hint: '예: 한강 저녁 러닝',
                maxLength: kRunTitleMaxLength,
                enabled: !_saving,
                autofocus: true,
              ),
              const SizedBox(height: AppTokens.s16),
              _Field(
                label: '메모',
                controller: _note,
                hint: '오늘 컨디션, 코스, 느낀 점을 남겨 보세요',
                maxLength: kRunNoteMaxLength,
                enabled: !_saving,
                maxLines: 4,
              ),
              if (_error != null) ...[
                const SizedBox(height: AppTokens.s12),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFD32F2F),
                  ),
                ),
              ],
              const SizedBox(height: AppTokens.s24),
              Row(
                children: [
                  Expanded(
                    child: _SheetButton(
                      label: '취소',
                      onTap: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      filled: false,
                    ),
                  ),
                  const SizedBox(width: AppTokens.s12),
                  Expanded(
                    child: _SheetButton(
                      label: '저장',
                      onTap: _saving ? null : _save,
                      filled: true,
                      busy: _saving,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 입력 길이를 **코드포인트(룬)** 기준으로 제한한다.
///
/// Flutter 기본 [LengthLimitingTextInputFormatter]는 grapheme cluster로 세는데,
/// 서버(`char_length`/`left`)와 `normalizeRunMetaField()`는 코드포인트로 센다.
/// `👨‍👩‍👧‍👦`는 1 grapheme이지만 7 코드포인트라, 기본 포매터를 쓰면 UI가 서버보다
/// 관대해지고 초과분이 서버에서 조용히 잘린다 — 이모지가 반토막 난 채 저장된다.
/// **서버가 진실이므로 클라이언트는 서버보다 관대할 수 없다**(QA C-3).
///
/// 초과 입력을 통째로 거절하지 않고 잘라서 받는 이유는 붙여넣기 때문이다 —
/// 500자를 넘는 메모를 붙였을 때 아무것도 안 들어가는 것보다 앞부분이 들어가는
/// 편이 낫다.
///
/// 절단 지점은 **룬 예산 안에서 grapheme 경계**다. 룬 경계에서 그냥 자르면 서버가
/// 하는 것과 같은 반토막 이모지가 나온다 — 어차피 서버 상한을 넘길 수 없으니,
/// 클라이언트에서는 한 글자 덜 받고 온전한 문자만 남기는 편이 낫다. 서버보다
/// 관대해지지 않으므로(≤ 상한) 계약을 깨지 않는다.
@visibleForTesting
class RuneLimitingTextInputFormatter extends TextInputFormatter {
  const RuneLimitingTextInputFormatter(this.maxRunes);

  final int maxRunes;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= maxRunes) return newValue;

    final buffer = StringBuffer();
    var used = 0;
    for (final grapheme in newValue.text.characters) {
      final cost = grapheme.runes.length;
      if (used + cost > maxRunes) break;
      buffer.write(grapheme);
      used += cost;
    }

    final truncated = buffer.toString();
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.maxLength,
    required this.enabled,
    this.hint,
    this.maxLines = 1,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLength;
  final bool enabled;
  final int maxLines;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF616161),
          ),
        ),
        const SizedBox(height: AppTokens.s8),
        TextField(
          controller: controller,
          enabled: enabled,
          autofocus: autofocus,
          maxLines: maxLines,
          // 서버는 상한을 넘기면 조용히 자른다(TRD §4.4). 잘린 뒤에야 알게 하는
          // 대신 입력 단계에서 막는다 — 카운터가 남은 글자를 계속 보여준다.
          //
          // ⚠️ 기본 `maxLength`(= `LengthLimitingTextInputFormatter`)를 쓰지 않는다.
          // 그쪽은 **grapheme cluster** 단위로 세는데 서버 `left()`/`char_length()`와
          // `normalizeRunMetaField()`는 **코드포인트** 단위다. `👨‍👩‍👧‍👦`(1 grapheme /
          // 7 코드포인트)가 섞이면 UI는 통과시키고 서버가 이모지를 반토막 내
          // 조용히 저장한다(QA C-3). 서버가 진실이므로 클라이언트가 더 관대하면
          // 안 된다 — 포매터도 카운터도 룬으로 맞춘다.
          inputFormatters: [RuneLimitingTextInputFormatter(maxLength)],
          // `maxLength`는 카운터 표시용으로만 남기고 강제는 위 포매터가 한다
          // (none이 아니면 Flutter가 grapheme 기준 포매터를 하나 더 끼워 넣는다).
          maxLength: maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.none,
          // 카운터도 룬으로 센다. `ValueListenableBuilder`로 감싸는 이유는
          // 이 콜백이 컨트롤러 변경마다 다시 불린다는 보장이 없어서다.
          buildCounter: (
            context, {
            required int currentLength,
            required bool isFocused,
            required int? maxLength,
          }) =>
              ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => Text(
              '${value.text.runes.length}/$maxLength',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9B)),
            ),
          ),
          textInputAction:
              maxLines == 1 ? TextInputAction.next : TextInputAction.newline,
          style: const TextStyle(fontSize: 15, color: Colors.black),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF9B9B9B)),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppTokens.s12,
              vertical: AppTokens.s12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTokens.rMd),
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.onTap,
    required this.filled,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = filled
        ? (onTap == null ? scheme.primary.withValues(alpha: 0.5) : scheme.primary)
        : Colors.transparent;
    final foreground = filled ? scheme.onPrimary : const Color(0xFF616161);

    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.rMd),
        child: Container(
          height: AppTokens.minTapTarget,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppTokens.rMd),
            border: filled
                ? null
                : Border.all(color: const Color(0xFFE0E0E0)),
          ),
          child: busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(foreground),
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
        ),
      ),
    );
  }
}
