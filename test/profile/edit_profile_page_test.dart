import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/error/failure.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/user_repository.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/profile/data/avatar_service.dart';
import 'package:runnit/features/profile/presentation/edit_profile_page.dart';
import 'package:runnit/models/models.dart';

/// AC-02 프로필 편집 화면.
///
/// 이 화면의 위험은 렌더링이 아니라 **저장 경로**에 몰려 있다 — 빈 입력이
/// null로 저장되는지, 범위를 벗어난 값이 서버까지 가지 않는지, 아바타 업로드와
/// 프로필 갱신의 순서(그리고 실패 시 되돌리기)가 맞는지. 그래서 테스트도
/// 리포지토리가 실제로 무엇을 받았는지를 본다.
void main() {
  const myId = 'user-me';

  AppUser profile({
    String? displayName = '러너A',
    double? weightKg = 70,
    double? weeklyGoalKm = 30,
    String? avatarUrl,
  }) =>
      AppUser(
        id: myId,
        username: 'runner_a',
        displayName: displayName,
        avatarUrl: avatarUrl,
        weightKg: weightKg,
        weeklyGoalKm: weeklyGoalKm,
        heightCm: 177,
        createdAt: DateTime.utc(2026, 1, 1),
      );

  Future<_Harness> pump(
    WidgetTester tester, {
    AppUser? user,
    bool saveFails = false,
    PickedAvatar? pickResult,
  }) async {
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _FakeUserRepository(user: user, fails: saveFails);
    final storage = _FakeAvatarStorage();
    final picker = _FakeAvatarPicker(pickResult);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue(myId),
          userRepositoryProvider.overrideWithValue(repo),
          avatarStorageProvider.overrideWithValue(storage),
          avatarPickerProvider.overrideWithValue(picker),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          // 저장 성공 시 `Navigator.pop`을 하므로 아래에 화면이 하나 있어야 한다.
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EditProfilePage(),
                    ),
                  ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    return _Harness(repo, storage, picker);
  }

  Finder fieldAfter(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(Row),
      );

  testWidgets('현재 값으로 폼을 채우고 username은 읽기 전용으로 보여준다',
      (tester) async {
    await pump(tester, user: profile());

    expect(find.text('프로필 편집'), findsOneWidget);
    expect(find.text('runner_a'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    // `70.0`이 아니라 `70`으로 보여야 한다 — 사용자가 입력한 적 없는 소수점.
    expect(find.text('70'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('러너A'), findsOneWidget);

    // 편집 대상이 아닌 신장은 폼에 없다.
    expect(fieldAfter('신장 (cm)'), findsNothing);
  });

  testWidgets('체중이 CHECK 범위를 벗어나면 저장하지 않는다', (tester) async {
    final h = await pump(tester, user: profile());

    await tester.enterText(find.widgetWithText(TextFormField, '70'), '500');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('20~400kg 범위로 입력해 주세요'), findsOneWidget);
    expect(h.repo.saved, isNull);
  });

  testWidgets('주간 목표 0은 "미설정"이 아니라 오류다', (tester) async {
    // 서버 CHECK가 `weekly_goal_km > 0`이다. 목표를 지우려면 빈 값이어야 한다.
    final h = await pump(tester, user: profile());

    await tester.enterText(find.widgetWithText(TextFormField, '30'), '0');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.textContaining('범위로 입력해 주세요'), findsOneWidget);
    expect(h.repo.saved, isNull);
  });

  testWidgets('빈 입력은 null로 저장한다 — 표시이름/체중/주간목표', (tester) async {
    final h = await pump(tester, user: profile());

    await tester.enterText(find.widgetWithText(TextFormField, '러너A'), '   ');
    await tester.enterText(find.widgetWithText(TextFormField, '70'), '');
    await tester.enterText(find.widgetWithText(TextFormField, '30'), '');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    final saved = h.repo.saved!;
    expect(saved.displayName, isNull);
    expect(saved.weightKg, isNull);
    expect(saved.weeklyGoalKm, isNull);
    // 편집 대상이 아닌 필드는 그대로 실려 간다(값이 지워지면 안 된다).
    expect(saved.heightCm, 177);
    expect(saved.username, 'runner_a');
  });

  testWidgets('정상 값은 그대로 저장하고 화면을 닫는다', (tester) async {
    final h = await pump(tester, user: profile());

    await tester.enterText(find.widgetWithText(TextFormField, '러너A'), '새이름');
    await tester.enterText(find.widgetWithText(TextFormField, '70'), '65.5');
    await tester.enterText(find.widgetWithText(TextFormField, '30'), '42');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    final saved = h.repo.saved!;
    expect(saved.displayName, '새이름');
    expect(saved.weightKg, 65.5);
    expect(saved.weeklyGoalKm, 42);
    expect(find.text('프로필을 저장했어요'), findsOneWidget);
    // pop 되어 원래 화면으로 돌아왔다.
    expect(find.text('열기'), findsOneWidget);
  });

  testWidgets('사진을 고르면 업로드 후 새 URL을 저장하고 이전 파일을 지운다',
      (tester) async {
    const oldUrl =
        'https://x.supabase.co/storage/v1/object/public/avatars/$myId/old.jpg';
    final h = await pump(
      tester,
      user: profile(avatarUrl: oldUrl),
      pickResult: PickedAvatar(
        fileName: 'photo.png',
        bytes: Uint8List.fromList(const [1, 2, 3]),
      ),
    );

    await tester.tap(find.text('사진 변경'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(h.storage.uploaded, hasLength(1));
    expect(h.repo.saved!.avatarUrl, h.storage.uploadedUrl);
    // 순서: 업로드 → 프로필 갱신 → 옛 파일 삭제.
    expect(h.storage.removed, [oldUrl]);
  });

  testWidgets('프로필 갱신이 실패하면 방금 올린 아바타를 되돌린다', (tester) async {
    final h = await pump(
      tester,
      user: profile(),
      saveFails: true,
      pickResult: PickedAvatar(
        fileName: 'photo.png',
        bytes: Uint8List.fromList(const [1, 2, 3]),
      ),
    );

    await tester.tap(find.text('사진 변경'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.textContaining('네트워크 상태를 확인해 주세요'), findsOneWidget);
    // 고아 파일이 남지 않아야 한다.
    expect(h.storage.removed, [h.storage.uploadedUrl]);
    // 화면은 닫히지 않는다(사용자가 다시 시도할 수 있어야 한다).
    expect(find.text('저장'), findsOneWidget);
  });

  testWidgets('지원하지 않는 확장자는 업로드 전에 막는다', (tester) async {
    final h = await pump(
      tester,
      user: profile(),
      pickResult: PickedAvatar(
        fileName: 'photo.gif',
        bytes: Uint8List.fromList(const [1, 2, 3]),
      ),
    );

    await tester.tap(find.text('사진 변경'));
    await tester.pumpAndSettle();

    expect(find.text('JPG · PNG · WebP 이미지만 올릴 수 있어요.'), findsOneWidget);
    expect(h.storage.uploaded, isEmpty);
  });

  testWidgets('2MiB를 넘는 이미지는 이유를 알리고 막는다', (tester) async {
    final h = await pump(
      tester,
      user: profile(),
      pickResult: PickedAvatar(
        fileName: 'huge.jpg',
        bytes: Uint8List(AvatarPolicy.maxBytes + 1),
      ),
    );

    await tester.tap(find.text('사진 변경'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2MB를 넘어요'), findsOneWidget);
    expect(h.storage.uploaded, isEmpty);
  });

  testWidgets('외부 아바타 URL(우리 버킷이 아님)은 삭제 대상이 아니다', (tester) async {
    // 카카오 CDN 등 소셜 로그인이 준 URL이 여기로 들어올 수 있다.
    expect(
      AvatarPolicy.objectPathOf('https://k.kakaocdn.net/img/profile.jpg'),
      isNull,
    );
    expect(
      AvatarPolicy.objectPathOf(
        'https://x.supabase.co/storage/v1/object/public/avatars/u1/a.jpg?t=1',
      ),
      'u1/a.jpg',
    );
  });

  testWidgets('프로필 로딩 실패는 재시도 버튼과 함께 안내한다', (tester) async {
    await pump(tester, user: null);
    expect(find.text('프로필을 불러오지 못했어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
  });
}

class _Harness {
  _Harness(this.repo, this.storage, this.picker);

  final _FakeUserRepository repo;
  final _FakeAvatarStorage storage;
  final _FakeAvatarPicker picker;
}

class _FakeUserRepository implements UserRepository {
  _FakeUserRepository({this.user, this.fails = false});

  final AppUser? user;
  final bool fails;
  AppUser? saved;

  @override
  Future<AppUser?> currentUser() async => user;

  @override
  Future<AppUser?> findById(String userId) async => user;

  @override
  Stream<AppUser?> watchCurrentUser() => Stream.value(user);

  @override
  Future<AppUser> updateProfile(AppUser user) async {
    if (fails) throw const Failure.network(message: 'boom', statusCode: 500);
    saved = user;
    return user;
  }
}

class _FakeAvatarStorage implements AvatarStorage {
  final List<PickedAvatar> uploaded = [];
  final List<String> removed = [];

  String get uploadedUrl =>
      'https://x.supabase.co/storage/v1/object/public/avatars/user-me/new.png';

  @override
  Future<String> upload(String userId, PickedAvatar avatar) async {
    uploaded.add(avatar);
    return uploadedUrl;
  }

  @override
  Future<void> removeByPublicUrl(String url) async => removed.add(url);
}

class _FakeAvatarPicker implements AvatarPicker {
  _FakeAvatarPicker(this.result);

  final PickedAvatar? result;

  @override
  Future<PickedAvatar?> pickFromGallery() async => result;
}
