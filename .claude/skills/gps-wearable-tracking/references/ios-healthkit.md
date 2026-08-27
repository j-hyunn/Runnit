# iOS — background location + HealthKit

## Background location tracking

Declare `NSLocationAlwaysAndWhenInUseUsageDescription` in `Info.plist` and enable `Location updates` in the Background Modes capability.

Always request permission in stages:
1. First request only "Allow While Using the App" (`whenInUse`)
2. At the run-start moment, request the upgrade to "Always Allow" (`requestAlwaysAuthorization`) — requesting "Always Allow" right at first launch makes the system treat it as likely-to-be-denied and use stronger dialog wording

Set `CLLocationManager`'s `allowsBackgroundLocationUpdates = true` together with `pausesLocationUpdatesAutomatically = false` (so the system doesn't auto-stop tracking when you pause during a run).

## HealthKit integration (Apple Watch)

```
1. Declare NSHealthShareUsageDescription, NSHealthUpdateUsageDescription in Info.plist
2. Request HKHealthStore permissions: HKQuantityType(.heartRate, .distanceWalkingRunning), HKWorkoutType
3. If there is a watchOS companion app: real-time watch-phone comms via WCSession; if not: query the recorded workout from HealthKit after the fact via HKWorkoutSession
4. For users who record workouts on the watch alone, also consider subscribing to new-workout saves via HKObserverQuery to auto-reflect them in the app
```

## Garmin data comes in through this path too

For a user who turned on "Apple Health" sync in the Garmin Connect app, the Garmin watch's workout records (distance, heart rate, GPS route) are saved automatically into HealthKit. That is, if you implement item 3's query (HKWorkoutSession after-the-fact lookup) to include all workout sources rather than limiting to Apple Watch, you support Apple Watch and Garmin at once with no separate Garmin-specific code. You can tell which app recorded it (Garmin Connect vs your own app) via `HKWorkout`'s `sourceRevision.source.name`.

## watchOS companion app (optional advanced feature)

A dedicated watchOS app lets you start/stop a run right from the watch screen and send real-time data to the phone via `WCSession`. This is a large task requiring a separate project target, so for the initial version, start with after-the-fact data lookup via HealthKit (item 3) and split the companion app into a later phase.

## Known pitfalls

- HealthKit permissions don't let the app distinguish "denied" from "not asked yet" (an iOS privacy design) — instead of branching UI on permission state, always prepare a fallback UI for when the actual data query comes back empty
- HealthKit works only partially in the simulator, so real-device testing is needed
