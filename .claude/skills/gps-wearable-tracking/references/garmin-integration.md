# Garmin integration

Garmin is a priority wearable support target for this app (on par with Apple Watch), but unlike Apple Watch it **does not communicate with the device directly**. Approach the integration in stages.

## Stage 1 (recommended for MVP): via Garmin Connect sync

When a Garmin watch records a run, it sends the data to the Garmin Connect app (which the user most likely already has installed). Garmin Connect can turn on the following syncs in its settings:
- iOS: "Apple Health" sync → written to HealthKit → see the "Garmin data comes in through this path too" section of [ios-healthkit.md](ios-healthkit.md)
- Android: Health Connect sync → see the same section of [android-health-connect.md](android-health-connect.md)

**Pro:** you can support Garmin using only the HealthKit/Health Connect path you already built, with no separate Garmin SDK integration or developer approval.
**Con:** it is not real-time — data only comes over once the Garmin watch finishes its Bluetooth sync with the Garmin Connect app (usually within a few minutes after the run ends). Live map display during the run must still rely on phone GPS (see the SKILL.md body).
**User guidance:** show a line like "Watch heart-rate/distance data is reflected after Garmin Connect syncs" on the record-detail screen so the late-filling data is not mistaken for a bug.

## Stage 2 (advanced, consider after MVP): direct Garmin Health API integration

If real-time fidelity becomes truly necessary, you can receive activity data directly from Garmin's servers via webhook/polling through the Garmin Health API (formerly Garmin Health SDK).
- Requires joining the Garmin Developer Program and getting the app approved (not usable immediately, review takes time)
- Requires a separate OAuth-based user-linking flow
- It is closer to "webhook push after the activity ends" than real-time streaming, so if you expect full real-time (second-by-second during the run) integration, phone GPS must still be the primary data source

**Recommendation:** start with Stage 1, and consider Stage 2 when real user feedback shows sync lag is a problem. Do not delay development from the start waiting on Garmin Health API review.

## Distinguishing the source from Apple Watch

Whether you need to distinguish the watch brand instead of a single `watch` value in `RunSample.source` is only worth considering when there is a gamification need (per-device badges, etc.). The HealthKit/Health Connect path can already distinguish the record source (Apple Watch itself vs via Garmin Connect) with `sourceRevision`/`dataOrigin`, so if a model extension is needed, pass this distinguishing info to the mobile-architect.
