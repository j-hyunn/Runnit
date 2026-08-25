import 'package:flutter/material.dart';

/// 앱 테마의 단일 진입점. 색/타이포 토큰의 실제 디자인 시스템은
/// flutter-ui-designer가 확장한다. 여기서는 골격만 제공한다.
class AppTheme {
  const AppTheme._();

  /// 브랜드 시드 컬러(러닝 = 활력 있는 그린). 디자이너 확정 시 교체.
  static const Color seed = Color(0xFF00C853);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Figma 전 화면이 Pretendard Variable을 쓴다 — 테마에 한 번만 지정하면
      // fontFamily를 명시하지 않은 모든 TextStyle이 이걸 상속받는다.
      fontFamily: 'Pretendard Variable',
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
      ),
    );
  }
}
