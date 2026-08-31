import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/supabase_client.dart';
import '../../../core/api/supabase_error.dart';
import '../../../core/error/failure.dart';

/// AC-02 프로필 사진 — **고르기**와 **올리기**를 나눠 둔 두 계약.
///
/// 화면(`edit_profile_page.dart`)이 `image_picker`와 `SupabaseClient`를 직접
/// 부르지 않는 이유는 하나다: 그러면 이 화면을 위젯 테스트로 돌릴 수 없다.
/// 둘 다 플랫폼 채널(갤러리 피커)과 네트워크에 붙어 있어서 테스트 환경에서는
/// 어떤 형태로도 성공하지 않는다. provider로 갈라 두면 테스트가 가짜 구현으로
/// 갈아끼울 수 있다.

/// 사용자가 고른 이미지 한 장. 이미 리사이즈·재인코딩이 끝난 바이트다.
class PickedAvatar {
  const PickedAvatar({required this.fileName, required this.bytes});

  /// 원본 파일명 — **확장자만** 쓴다(업로드 경로는 새로 만든다).
  final String fileName;
  final Uint8List bytes;

  int get byteLength => bytes.length;
}

abstract interface class AvatarPicker {
  /// 갤러리에서 한 장 고른다. 사용자가 취소하면 null.
  Future<PickedAvatar?> pickFromGallery();
}

abstract interface class AvatarStorage {
  /// [userId]의 폴더에 새 파일로 올리고 **공개 URL**을 돌려준다.
  Future<String> upload(String userId, PickedAvatar avatar);

  /// 이전 아바타 파일을 지운다. 우리 버킷의 URL이 아니면 아무것도 하지 않는다.
  Future<void> removeByPublicUrl(String url);
}

/// Storage 계약(마이그레이션 54, `_workspace/20260831_154000_backend_ac02-ac03.md` §3).
class AvatarPolicy {
  const AvatarPolicy._();

  static const bucket = 'avatars';

  /// 버킷 `file_size_limit`. 초과분은 storage API가 업로드 **전에** 거절하므로
  /// 화면에서 먼저 걸러 사용자에게 이유를 알려준다.
  static const maxBytes = 2 * 1024 * 1024;

  /// 버킷 `allowed_mime_types`와 1:1.
  static const Map<String, String> mimeByExtension = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
  };

  /// 업로드 전 리사이즈 목표(장변 px). backend 권장값 — 2 MiB 상한을 UI 단에서
  /// 미리 만족시키기 위한 것이지 화질 규격이 아니다.
  static const resizeEdge = 512.0;

  /// 공개 URL은 `.../storage/v1/object/public/avatars/{uid}/{file}` 꼴이다.
  static const _publicMarker = '/object/public/$bucket/';

  static String? extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// 공개 URL에서 버킷 내부 경로(`{uid}/{file}`)를 뽑는다. 우리 버킷이 아니면
  /// null — 소셜 로그인이 준 외부 아바타 URL(카카오 CDN 등)이 여기로 들어올 수
  /// 있고, 그건 지울 대상이 아니다.
  static String? objectPathOf(String url) {
    final at = url.indexOf(_publicMarker);
    if (at < 0) return null;
    final path = url.substring(at + _publicMarker.length);
    // 쿼리스트링(`?t=`)이 붙어 오는 경우가 있어 잘라낸다.
    final q = path.indexOf('?');
    final clean = q < 0 ? path : path.substring(0, q);
    return clean.isEmpty ? null : Uri.decodeComponent(clean);
  }
}

class ImagePickerAvatarPicker implements AvatarPicker {
  ImagePickerAvatarPicker([ImagePicker? picker])
      : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedAvatar?> pickFromGallery() async {
    // 리사이즈·재인코딩을 네이티브에 맡긴다. `maxWidth == maxHeight`라 비율은
    // 유지된 채 장변이 512px에 맞춰지고, 그 결과가 사실상 2 MiB 상한을 보장한다.
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: AvatarPolicy.resizeEdge,
      maxHeight: AvatarPolicy.resizeEdge,
      imageQuality: 85,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return PickedAvatar(fileName: file.name, bytes: bytes);
  }
}

class SupabaseAvatarStorage implements AvatarStorage {
  const SupabaseAvatarStorage(this._client);

  final SupabaseClient _client;

  @override
  Future<String> upload(String userId, PickedAvatar avatar) {
    return guardSupabase(() async {
      final ext = AvatarPolicy.extensionOf(avatar.fileName) ?? 'jpg';
      final mime = AvatarPolicy.mimeByExtension[ext];
      if (mime == null) {
        throw Failure.storage(message: '지원하지 않는 이미지 형식이에요($ext).');
      }
      if (avatar.byteLength > AvatarPolicy.maxBytes) {
        throw const Failure.storage(message: '이미지 용량이 2MB를 넘어요.');
      }

      // **경로 규약**: 첫 폴더 세그먼트가 곧 쓰기 권한 술어다
      // (`(storage.foldername(name))[1] = auth.uid()`). 어기면 42501.
      //
      // 같은 경로를 덮어쓰지 않고 타임스탬프로 새 경로를 만든다 — 덮어쓰면
      // CDN/이미지 캐시 때문에 앱에 옛 사진이 그대로 남는다(backend §3).
      final path =
          '$userId/${DateTime.now().toUtc().millisecondsSinceEpoch}.$ext';

      final bucket = _client.storage.from(AvatarPolicy.bucket);
      await bucket.uploadBinary(
        path,
        avatar.bytes,
        fileOptions: FileOptions(contentType: mime),
      );
      return bucket.getPublicUrl(path);
    });
  }

  @override
  Future<void> removeByPublicUrl(String url) async {
    final path = AvatarPolicy.objectPathOf(url);
    if (path == null) return;
    // 이 삭제는 **실패해도 사용자 흐름을 막지 않는다** — 프로필은 이미 새
    // 사진으로 갱신됐고, 남은 파일은 용량만 차지할 뿐 화면에 나타나지 않는다.
    // 여기서 예외를 올리면 "저장은 됐는데 에러가 뜨는" 상태가 된다.
    try {
      await _client.storage.from(AvatarPolicy.bucket).remove([path]);
    } catch (_) {
      // 무시(위 주석).
    }
  }
}

final avatarPickerProvider = Provider<AvatarPicker>(
  (ref) => ImagePickerAvatarPicker(),
);

final avatarStorageProvider = Provider<AvatarStorage>(
  (ref) => SupabaseAvatarStorage(ref.watch(supabaseClientProvider)),
);
