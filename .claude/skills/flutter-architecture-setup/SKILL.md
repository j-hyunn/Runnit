---
name: flutter-architecture-setup
description: "Provides the design workflow for the Flutter running app's project structure, state management (Riverpod), and core data models (freezed). Covers entity design for RunRecord/RunSample/User/Badge/RankingEntry, the feature-first folder convention, and package-selection criteria. Use whenever a request is about 'set up the project structure', 'what state management to use', 'data model design'."
---

# Flutter architecture setup

The procedure for designing the skeleton (folder structure, state management, data models) of the Flutter running app.

> 📌 **`docs/PRD.md` is the single source of truth for product spec.** When this skill conflicts with the PRD, the PRD wins. Always confirm the distinction between tier (quarterly season · absolute) and weekly ranking (within tier · relative), and that crews are P2, before working.
>
> 📐 For implementation-structure detail, see `docs/ARCHITECTURE.md` §3~§4 (client architecture · data model) and `docs/TRD.md` §2~§3 (packages · Dart model code) — if this skill's example code differs from the TRD, update the TRD to the current baseline.

## 1. Folder structure — feature-first

Use a feature-first structure rather than layer-first (splitting everything into `models/`, `screens/`, `services/`). When several specialists work in parallel on feature areas (tracking/gamification/backend/UI) like this app, a layer-first structure easily makes code from different features collide in the same folder.

```
lib/
  core/                    # shared utils, router, theme, DI
  models/                  # shared data models (owned by mobile-architect)
    run_sample.dart
    run_record.dart
    user.dart
    badge.dart
    ranking_entry.dart
  features/
    tracking/               # gps-tracking-engineer
      data/ domain/ presentation/
    gamification/           # gamification-designer
      data/ domain/ presentation/
    ranking/
    profile/
  core/api/                 # the Supabase client built by backend-engineer
```

Split each `features/{name}/` into `data` (external integration) / `domain` (business logic) / `presentation` (widgets). This way the flutter-ui-designer touches only `presentation/` and the backend-engineer only `data/`, reducing file collisions.

## 2. State management — Riverpod as the default

Compile-time safety (catches Provider typos at build time), testability (easy mocking via Provider override), and a good fit for this app's need for multiple screens to subscribe to state that updates in the background (like a GPS stream).

- `StreamProvider`: GPS position stream, live ranking subscription
- `NotifierProvider`: run-session state (running/paused/ended), badge-earned queue
- `FutureProvider`: one-shot async data like history queries and leaderboard queries

If the user already specified another state-management solution (Bloc, Provider, etc.), follow it — Riverpod is a justified default, not a mandate.

## 3. Core data models

Auto-generate immutable models and serialization with freezed + json_serializable. Manual `toJson`/`fromJson` easily drops fields when new ones are added.

```dart
@freezed
class RunSample with _$RunSample {
  const factory RunSample({
    required double lat,
    required double lng,
    required DateTime timestamp,
    double? altitude,
    int? heartRate,       // present only with wearable integration
    required RunSampleSource source, // phone | watch
  }) = _RunSample;
}

@freezed
class RunRecord with _$RunRecord {
  const factory RunRecord({
    required String id,
    required String userId,
    required DateTime startedAt,
    required DateTime endedAt,
    required double distanceMeters,
    required Duration duration,
    required List<RunSample> samples,
    int? avgHeartRate,
  }) = _RunRecord;
}
```

**Core principle: merge phone GPS and watch sensor data into one `RunSample`.** Distinguish only by the `source` field. Separate models per source (`PhoneRunSample`, `WatchRunSample`) duplicate source-branching logic in all three of gamification, backend, and UI.

Other core models:
- `User` — profile; whether to include cached cumulative-stat fields (total distance, total run count) is a trade-off against batch-recompute cost
- `Badge` (catalog) / `UserBadge` (earn record, including earned-at time)
- `RankingEntry` — period, rank, score, tie-break reference value

## 4. Package-selection criteria

| Purpose | Recommended package | Note |
|---------|--------------------|------|
| GPS | `geolocator` | background support, accuracy options |
| Wearable sensors | `health` | HealthKit/Health Connect unified wrapper |
| Permissions | `permission_handler` | unified iOS/Android permission flow |
| State management | `flutter_riverpod` + `riverpod_generator` | see §2 |
| Immutable models | `freezed` + `json_serializable` | see §3 |
| Routing | `go_router` | deep links, nested routes |
| Map | `flutter_map` (open source, no cost) or `google_maps_flutter` (richer UX, needs API key) | choose by budget / UX requirements |
| Charts | `fl_chart` | pace/distance trend visualization |
| Backend | Supabase (`supabase_flutter`) | Supabase MCP is connected in this environment, so agree with backend-engineer |

## 5. Module-interface principle

The GPS-tracking module does not depend directly on the backend/gamification modules — abstract it to emit `RunRecord` via a stream/callback. This lets you test tracking logic independently of gamification logic, and even if tracking sources grow later (e.g. treadmill integration) no downstream-module changes are needed.
