pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // ── FCM(PRD §5.10) ────────────────────────────────────────────────
    // Firebase 프로젝트를 만들고 `android/app/google-services.json`을 넣은 뒤
    // 아래 두 줄의 주석을 함께 해제한다(여기 + app/build.gradle.kts).
    // ⚠️ 설정 파일 없이 플러그인만 적용하면 **빌드가 실패한다**
    //    ("File google-services.json is missing"). 그래서 지금은 꺼 둔다 —
    //    이 상태에서도 앱은 뜨고, 푸시만 비활성이다
    //    (`lib/core/notifications/firebase_bootstrap.dart`).
    // id("com.google.gms.google-services") version "4.4.2" apply false
}

include(":app")
