---
name: flutter-ui-patterns
description: "Screen-implementation patterns for the Flutter running app — live-tracking-screen performance optimization, map/chart widgets, badge-earned presentation, design tokens, empty/loading/error state handling. Use for 'build the tracking screen', 'ranking UI', 'badge gallery', 'draw the route on the map' requests."
---

# Flutter UI patterns — running app

Patterns to follow when implementing the running app's screens.

> 📌 **`docs/PRD.md` is the single source of truth for product spec.** When this skill conflicts with the PRD, the PRD wins. Always confirm the distinction between tier (quarterly season · absolute) and weekly ranking (within tier · relative), and that crews are P2, before working.
>
> 📐 The baseline for data shapes is `docs/TRD.md` §3 (Dart model definitions). The field names/types a screen consumes follow that spec.

## 1. Live-tracking screen — narrow the rebuild scope

GPS updates every second, so wrapping the whole screen in one `Consumer` redraws even the map on every update and drops frames. Split areas that update at different rates:

```dart
Column(
  children: [
    Consumer(builder: (_, ref, __) {
      final position = ref.watch(currentPositionProvider); // updates every second
      return MapWidget(position: position);
    }),
    Consumer(builder: (_, ref, __) {
      final stats = ref.watch(runStatsProvider); // distance/pace, also updates often but is a separate widget from the map, so its rebuild is isolated from the map repaint
      return StatsPanel(stats: stats);
    }),
  ],
)
```

The map widget itself should avoid recomputing the whole polyline every frame — prefer an approach that only appends new points (`addLatLng`-style APIs).

## 2. Map route visualization

- `flutter_map`: open source, no API key needed, shows the route via a polyline layer
- `google_maps_flutter`: choose it if you need a richer UX (3D, indoor maps); API key and cost apply

Use the smoothed `RunSample` list from the gps-tracking-engineer directly for the route polyline — redrawing raw GPS points makes the map zigzag.

## 3. Chart/stat visualization

When showing pace/distance trends with `fl_chart`:
- Axis labels overlap as the session count grows, so adjust the interval dynamically
- For empty data (before the first run) show an empty state first, do not render the chart

## 4. Badge-earned presentation

Badges are the core reward moment of gamification, so do not handle them as a plain toast:
- Full-screen overlay + scale animation to clearly express "achievement"
- If multiple badges are earned at once, queue them and show them sequentially (so multiple dialogs don't overlap)
- Use the actual field names of the `UserBadge` model defined by the gamification-designer (`earnedAt`, etc.) as-is — do not arbitrarily redefine fields

## 5. Ranking/leaderboard screen

- Pin the user's own rank at the top of the list (always visible without scrolling) — don't make the user scroll to see their rank
- To show rank movement (up/down) with arrows/color, you need to compare against a previous ranking snapshot — agree with the backend-engineer in advance
- Show the data-refresh time (how many minutes old the leaderboard cache is) to reduce user confusion

## 6. Design tokens

Define color/typography/spacing in `_workspace/{date}_ui_design_tokens.md` and apply them app-wide via `ThemeData`/`ThemeExtension`. Include gamification elements (per-tier badge colors: bronze/silver/gold) in the tokens for consistency.

## 7. State-handling principle

Every data-driven screen implements loading/error/empty states alongside the normal state:

```dart
data.when(
  data: (records) => records.isEmpty
      ? const EmptyRunHistoryView()
      : RunHistoryList(records: records),
  loading: () => const RunHistorySkeleton(),
  error: (e, _) => RunHistoryErrorView(onRetry: () => ref.refresh(...)),
)
```
