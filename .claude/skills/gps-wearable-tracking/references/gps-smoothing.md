# GPS smoothing and outlier removal

## Why it's needed

Raw GPS coordinates are several to tens of meters off the real position near city centers / indoors / tunnels. Using that error directly in distance calculation produces the "GPS drift" bug where distance accumulates even while stationary.

## Base filter: accuracy-based rejection

The simplest and most effective first-pass filter. Discard any point whose `Position.accuracy` (radius, meters) exceeds a threshold (e.g. 20m) outright.

```dart
if (position.accuracy > 20) return; // ignore low-confidence points
```

## Second filter: speed-based outlier removal

If the computed speed between two consecutive points exceeds a human running limit (e.g. 30 km/h — hard to exceed even over a 100m sprint), treat it as a GPS jump and exclude it.

```dart
final speedKmh = distanceBetween(prev, curr) / timeDelta.inSeconds * 3.6;
if (speedKmh > 30) {
  // treat this point as a jump, exclude from distance calculation (but keep prev as the reference point for the next comparison)
  return;
}
```

## Third filter: moving-average smoothing

To reduce the fine jitter (zigzag) of the coordinates themselves, correct the coordinate with a moving average of the last N points (e.g. 3~5) before drawing on the map and computing distance. If N is too large, real cornering (direction changes) is smeared, so consider adjusting N dynamically based on whether you're in a dense-building city area.

## Stationary detection

If the position change stays below a threshold (e.g. 3m) for a period (e.g. 10s+), decide "stationary" and completely exclude the fine GPS jitter during that window from distance calculation. This prevents distance being wrongly accumulated while waiting at traffic lights or during interval-run rest periods.

## Verification method

After implementing the smoothing logic, feed it a real GPS log (or synthetic data) of staying stationary for 5+ minutes and check that the computed distance is near zero. This is the most direct test that the smoothing actually works.
