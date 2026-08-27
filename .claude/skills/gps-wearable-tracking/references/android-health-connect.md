# Android — background location + Health Connect

## Background location tracking

From Android 10+, the background location permission (`ACCESS_BACKGROUND_LOCATION`) is separate from the foreground location permission. Declare it separately in the manifest, and request it at runtime through a separate dialog.

To keep tracking from breaking when the app goes to the background during a run session, use a **Foreground Service** (via `flutter_foreground_task` or `geolocator`'s background mode):
- Show a persistent notification so the user is aware tracking is active (mandatory per Android policy)
- The service can be killed by the system due to Doze mode / App Standby Buckets, so prompt the user for a battery-optimization exemption (`requestIgnoreBatteryOptimizations`) when the run starts

## Health Connect integration

Health Connect is Android's unified health-data store, and the standard path for reading GPS/heart-rate data from Wear OS watches.

```
1. Check whether the Health Connect app is installed (built into the OS on Android 14+, a separate app on earlier versions)
2. Request permissions: READ_HEART_RATE, READ_DISTANCE, READ_EXERCISE, etc.
3. The app that records workouts on the Wear OS watch (Google Fit, Samsung Health, etc.) must be writing data to Health Connect
4. Rather than real-time streaming during the run session, it is more stable to query the heart-rate/distance data for that time window after the session ends and merge it into the RunRecord
   (Health Connect's real-time stream API is limited, so collect real-time-critical location separately via geolocator)
```

## Garmin data comes in through this path too

On Android versions where the Garmin Connect app supports Health Connect sync, if the user turns on Health Connect integration in Garmin Connect's settings, the Garmin watch's workout records are written straight into Health Connect. If the query logic in item 3 does not filter by the source app, you support Wear OS devices and Garmin with the same code. Check the app that created the record (`dataOrigin`) in the `ExerciseSessionRecord` metadata to distinguish Garmin-Connect-originated data.

## Known pitfalls

- Some manufacturers' battery-management policies (Xiaomi, Huawei, etc.) aggressively kill background processes — there is no perfect fix, so always implement session resume (recovering an in-progress session on app relaunch)
- Health Connect permissions are fine-grained (per data type), so request only what you need — over-requesting raises the user denial rate
