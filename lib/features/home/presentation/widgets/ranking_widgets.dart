import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../models/models.dart';

/// 홈/전체 랭킹 화면이 공유하는 랭킹 행 관련 위젯. 두 화면(`home_page.dart`,
/// `full_ranking_page.dart`)에서 같은 시각 언어를 쓰기 위해 분리했다.

/// Figma 노드 `55:1260`("Tier", 카드 헤더 큰 배지)/`56:1441`("Tier", 목록 안
/// 작은 배지) — 방패 아이콘 + 티어 라벨. [background]로 톤온톤 필 배경 여부를
/// 명시적으로 고른다(2026-08-21: "내 티어는 뱃지 형식이 아니라 아이콘+텍스트만"
/// 요청에 따라 카드 헤더는 `background: false`로 쓴다 — 이전에는 아이콘 크기로
/// 배경 유무를 추측했는데, 그 암묵적 규칙을 없애고 호출부가 직접 정한다).
///
/// 방패 SVG(`assets/icons/tier_shield.svg`)는 브론즈 색(#A47300)이 하드코딩돼
/// 있어서 실제 티어 색으로 다시 칠하려고 `colorFilter`로 강제 틴트한다.
class TierPill extends StatelessWidget {
  const TierPill({
    super.key,
    required this.tier,
    this.iconSize = 16,
    this.fontSize = 12,
    this.background = true,
  });

  final Tier tier;
  final double iconSize;
  final double fontSize;
  final bool background;

  static Color colorFor(Tier tier) => switch (tier) {
        Tier.bronze => AppTokens.tierBronze,
        Tier.silver => AppTokens.tierSilver,
        Tier.gold => AppTokens.tierGold,
        Tier.platinum => AppTokens.tierPlatinum,
      };

  static String labelFor(Tier tier) => switch (tier) {
        Tier.bronze => 'Bronze',
        Tier.silver => 'Silver',
        Tier.gold => 'Gold',
        Tier.platinum => 'Platinum',
      };

  @override
  Widget build(BuildContext context) {
    final color = colorFor(tier);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SvgPicture.asset(
          'assets/icons/tier_shield.svg',
          width: iconSize,
          height: iconSize,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        ),
        const SizedBox(width: AppTokens.s4),
        Text(
          labelFor(tier),
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: background ? FontWeight.w600 : FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );

    if (!background) return content;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTokens.rPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s4, vertical: 2),
        child: content,
      ),
    );
  }
}

/// 프로필 사진 원형 아바타. 기본은 회색 원(Figma `#eee`)이고, [imageUrl] 또는
/// [imageBytes]가 주어지면 그 이미지를 원형으로 클리핑해 그린다.
///
/// 2026-08-31 AC-02/AC-03에서 이미지 지원을 추가했다. 랭킹 목록은 여전히 인자
/// 없이 호출해 회색 원만 쓴다 — `RankingEntry.avatarUrl`을 목록 전체에 걸어
/// 그리는 건 별개 판단이라 이번 범위에 넣지 않았다.
///
/// 로드 실패(끊긴 링크, 오프라인)는 **에러 위젯을 그리지 않고** 회색 원으로
/// 되돌아간다. 아바타는 보조 정보라, 깨진 이미지 아이콘이 뜨는 쪽이 더 나쁘다.
class ProfileCircle extends StatelessWidget {
  const ProfileCircle({
    super.key,
    required this.size,
    this.imageUrl,
    this.imageBytes,
  });

  final double size;
  final String? imageUrl;

  /// 아직 업로드하지 않은 로컬 선택 이미지의 미리보기(AC-02 편집 화면).
  /// [imageUrl]보다 우선한다 — 사용자가 방금 고른 사진이 항상 이겨야 한다.
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: Color(0xFFEEEEEE), shape: BoxShape.circle),
    );

    Widget? image;
    if (imageBytes != null) {
      image = Image.memory(
        imageBytes!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
      );
    } else if (imageUrl != null && imageUrl!.isNotEmpty) {
      image = Image.network(
        imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
      );
    }

    if (image == null) return placeholder;

    return ClipOval(
      child: SizedBox(width: size, height: size, child: image),
    );
  }
}

/// Figma 노드 `55:1359`("List 1") — 순위 숫자 없이 아바타/이름/티어/거리.
/// 티어 배지는 `entry.ownerTier`(행 소유자의 실제 개인 티어, 마이그레이션 24)를
/// 쓴다 — `entry.tier`는 보드의 조회 조건이라 "전체" 보드에서는 항상 null이다.
/// [highlighted]는 전체 랭킹 화면에서 "내 순위" 행을 표시할 때 쓴다.
///
/// [onTap]은 AC-03 타인 프로필(`/users/:id`) 진입점이다. 호출부가 넘겨주지
/// 않으면 행은 탭에 반응하지 않는다 — "누를 수 있어 보이는데 아무 일도 없는"
/// 상태를 만들지 않기 위해, 잉크 리플도 [onTap]이 있을 때만 붙는다.
class RunnerListTile extends StatelessWidget {
  const RunnerListTile({
    super.key,
    required this.entry,
    this.highlighted = false,
    this.onTap,
  });

  final RankingEntry entry;
  final bool highlighted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final name = entry.displayName ?? entry.username;

    final row = Row(
      children: [
        const ProfileCircle(size: 40),
        const SizedBox(width: AppTokens.s12),
        Text(
          highlighted ? '$name (나)' : name,
          style: TextStyle(
            fontSize: 16,
            fontWeight: highlighted ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
        if (entry.ownerTier != null) ...[
          const SizedBox(width: AppTokens.s8),
          TierPill(tier: entry.ownerTier!),
        ],
        const Spacer(),
        Text(
          Formatters.km(entry.score, fractionDigits: 1),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: Colors.black),
        ),
        const Text(
          ' km',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF616161)),
        ),
      ],
    );

    final Widget body;
    if (!highlighted) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.s8),
        child: row,
      );
    } else {
      body = Container(
        margin: const EdgeInsets.symmetric(vertical: AppTokens.s4),
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s12, vertical: AppTokens.s8),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(AppTokens.rMd),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
        ),
        child: row,
      );
    }

    if (onTap == null) return body;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.rMd),
      child: body,
    );
  }
}

class RunnerListSkeleton extends StatelessWidget {
  const RunnerListSkeleton({super.key, this.itemCount = 5});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < itemCount; i++) ...[
          if (i > 0) const SizedBox(height: AppTokens.s8),
          Container(
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(AppTokens.rMd),
            ),
          ),
        ],
      ],
    );
  }
}
