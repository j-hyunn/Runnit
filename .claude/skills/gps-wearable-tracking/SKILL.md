---
name: gps-wearable-tracking
description: "Implementation workflow for the Flutter running app's GPS location tracking and wearable integration (Apple Watch·Garmin first, HealthKit/Health Connect). Covers permission handling, background tracking, GPS smoothing, and distance/pace/calorie calculation. Use for 'implement GPS tracking', 'watch integration', 'Apple Watch integration', 'Garmin integration', 'keep recording in the background', 'distance calculation is off' requests."
---

# GPS & wearable tracking implementation

The procedure for accurately recording runs with phone GPS and wearable sensors.

> 📌 **`docs/PRD.md` is the single source of truth for product spec.** When this skill conflicts with the PRD, the PRD wins. Always confirm the distinction between tier (quarterly season · absolute) and weekly ranking (within tier · relative), and that crews are P2, before working.
>
> 📐 For implementation-structure detail, see `docs/ARCHITECTURE.md` §6 (GPS·wearable tracking architecture) and `docs/TRD.md` §8 (GPS/wearable tech spec).

## 1. Overall flow

```
request permission → start location stream (foreground service) → collect raw RunSamples
  → smoothing / outlier removal → compute distance·pace·calories → assemble RunRecord → publish session-end event
```

## 2. Permission handling

Request permissions in stages — requesting "Always Allow" up front raises the denial rate on both iOS and Android:
1. Request in-use location permission (`when in use`)
2. At the moment background tracking is actually needed (the start-run button), request the "Always Allow" upgrade
3. Wearable integration requests Health Connect/HealthKit permission separately (a distinct flow from location permission)

Load only the per-platform detail you need:
- Android implementation detail (Foreground Service, Health Connect — the common Garmin/Wear OS path) → [references/android-health-connect.md](references/android-health-connect.md)
- iOS implementation detail (Background Modes, HealthKit — the Apple Watch native + Garmin sync path) → [references/ios-healthkit.md](references/ios-healthkit.md)
- Garmin-specific detail (Garmin Connect sync settings, Garmin Health API overview) → [references/garmin-integration.md](references/garmin-integration.md)

## 3. Wearable priority and integration paths

This app treats Apple Watch and Garmin as priority support targets. The two devices have fundamentally different integration paths, so design them separately.

| Device | Integration path | Real-time fidelity | Priority |
|--------|-----------------|--------------------|----------|
| Apple Watch | HealthKit native (`HKWorkoutSession`, a watchOS companion app if needed) | High | 1st |
| Garmin | The Garmin Connect app syncs workout data into HealthKit (iOS) / Health Connect (Android) per the user's settings → the app reads it via that path | Low (sync lag) | 1st (different path but same support priority as Apple Watch) |
| Other Wear OS devices | Health Connect | Medium | 2nd |

**Key:** Garmin does not communicate with the device directly — it goes through the Garmin Connect sync. That means if you've already implemented HealthKit integration on iOS and Health Connect integration on Android, Garmin support is mostly "obtained for free" — it works without a separate Garmin-specific SDK integration. You only need to note the lack of real-time fidelity (sync lag) in the UI. When full real-time integration becomes truly necessary, consider direct Garmin Health API integration (requires developer approval), but it is not recommended for the MVP. Details: [references/garmin-integration.md](references/garmin-integration.md)

If no watch is connected or the user only has the phone, auto-fall-back to phone-only GPS tracking. This is not an error, it is a normal path — do not treat watch integration as a mandatory requirement that blocks tracking itself. Marking `RunSample.source` as `phone`/`watch` lets you distinguish the data origin in later sessions (see the mobile-architect's `RunSample` model). Whether to further subdivide the source value for Garmin vs Apple Watch (`watch:apple` vs `watch:garmin`) is agreed with the mobile-architect based on whether badges/stats need per-device distinction.

## 4. GPS smoothing — why it's needed

Raw GPS coordinates can be several to tens of meters off the real position near buildings/indoors/tunnels. Accumulating straight-line distance between consecutive coordinates without smoothing produces a bug where distance keeps growing from "GPS drift" even while stationary. Always compute distance after filtering. For algorithm detail and outlier-detection criteria, see [references/gps-smoothing.md](references/gps-smoothing.md).

## 5. Battery optimization

The GPS polling interval and accuracy (`LocationAccuracy`) directly affect battery drain. Recommend exposing the following as a user setting:

| Mode | Accuracy | Polling interval | Use |
|------|----------|-----------------|-----|
| High precision | best | 1~2s | races / PB-attempt runs |
| Standard | high | 5s | regular runs |
| Power saving | medium | 10s+ | long distance (marathon) |

## 6. Distance/pace/calorie calculation

- Distance: Haversine formula accumulated between smoothed consecutive points
- Pace: `duration / distance_km` (min/km); also providing per-segment (1km split) calculation is useful for both gamification and UI
- Calories: MET (Metabolic Equivalent)-based estimate — state in the UI that it's an estimate, not an exact value (a more precise estimate is possible with heart-rate data)

## 7. Deliverable

When `RunRecord` assembly finishes, publish a session-end event — the gamification-designer's badge evaluation and the backend-engineer's upload logic subscribe to it. Include the full final `RunRecord` (or its ID) in the event so subscribers don't need to recompute.
