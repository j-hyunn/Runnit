/// 완결된 러닝의 **1km 구간(랩) 분할** — 순수 함수, I/O 없음.
///
/// PRD TR-07 / HI-02의 "구간별(1km) 랩 기록"을 상세 화면 랩 테이블과
/// 페이스 그래프가 소비할 형태로 만든다.
///
/// ## 서버 규칙과의 정합성
/// 경계 통과 시각 산출은 서버 `_run_time_at_distance` / `_run_km_split_seconds`
/// (마이그레이션 41)와 **같은 규칙**이다 — km 경계를 사이에 둔 두 샘플 간
/// **누적거리 비율 선형 보간**. 워치 동기화 기록은 샘플 간격이 60초를 넘을 수
/// 있어 무보간 근사는 랩당 최대 1분 오차가 난다.
///
/// 서버 SQL의 분기를 그대로 옮긴 지점:
/// - 목표 거리 0 → 첫 샘플 시각
/// - 두 샘플의 누적거리 차가 0 → 보간하지 않고 뒤쪽 샘플 시각
/// - 어떤 샘플도 목표 거리에 못 미침 → 그 랩을 방출하지 않음
///
/// ## 서버와 **의도적으로 다른** 두 지점
/// 1. **자투리 구간.** 서버는 완주된 정수 km만 방출한다(`pace_variance_lte`가
///    자투리를 섞으면 왜곡되기 때문). 화면은 사용자가 실제로 뛴 마지막
///    600m를 감추면 "기록이 누락됐다"로 읽히므로 [LapSplit.isPartial]로
///    표시해 함께 내보낸다. 소비 측은 통계에서 자투리를 제외해야 한다.
/// 2. **거리 원천 폴백.** 서버 입력은 `cumulative_distance_meters`뿐이다.
///    클라이언트는 그 값이 없는 샘플(구버전 로컬 기록·일부 워치 임포트)에
///    한해 좌표 Haversine 누적으로 폴백한다 — 감추는 것보다 근삿값이라도
///    보여주는 편이 낫다. 폴백 경로에서는 서버 값과 미세하게 어긋날 수 있다.
///
/// ## 클라이언트 값은 표시용이다
/// 여기서 계산한 페이스는 뱃지·랭킹 판정에 쓰지 않는다. 서버가 원본 샘플로
/// 재계산한 값이 최종이며, 이 분할은 사용자가 방금 뛴 기록을 보여주기 위한
/// 것이다(ARCHITECTURE §7.2 클라이언트-서버 판정 미러링).
library;

import '../../../models/models.dart';
import '../../tracking/domain/gps_smoothing.dart' show haversineMeters;

/// 완전한 구간의 길이(m).
const double fullLapMeters = 1000.0;

/// 이 거리에 못 미치는 러닝은 랩을 만들지 않는다 — GPS 표류만으로도 수십 m가
/// 쌓여서, "0km 러닝"에 랩 테이블이 붙는 것을 막는다.
const double minSplittableMeters = 100.0;

/// 마지막 자투리 구간을 표시할 최소 길이(m). 이보다 짧으면 종료 직전 좌표
/// 흔들림에 가까워, 페이스가 의미 없는 값으로 튄다.
const double minPartialLapMeters = 50.0;

/// 러닝 1건의 한 구간(기본 1,000m, 마지막은 나머지).
class LapSplit {
  const LapSplit({
    required this.index,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.paceSecPerKm,
    required this.isPartial,
    this.avgHeartRateBpm,
    this.elevationGainMeters,
  });

  /// 1부터 시작하는 구간 번호.
  final int index;

  /// 이 구간의 실제 거리(m). 완전한 구간은 [fullLapMeters], 마지막은 그 미만.
  final double distanceMeters;

  /// 이 구간을 달린 시간(s) — 경계 보간 기준.
  final int durationSeconds;

  /// 이 구간의 페이스(s/km). 시간·거리가 0이면 0.
  final double paceSecPerKm;

  /// 1km를 채우지 못한 마지막 자투리 구간이면 true.
  ///
  /// 서버 `_run_km_split_seconds`는 이런 구간을 애초에 방출하지 않는다.
  /// 페이스 통계(평균·분산·최속)를 낼 때는 반드시 제외해야 한다.
  final bool isPartial;

  /// 구간 내 평균 심박수(bpm). 심박 샘플이 없으면 null.
  final int? avgHeartRateBpm;

  /// 구간 내 누적 상승 고도(m). 고도 데이터가 없으면 null.
  final double? elevationGainMeters;
}

/// [record]의 샘플에서 1km 랩을 계산한다.
///
/// 다음이면 빈 리스트를 반환한다(호출부는 랩 테이블·그래프를 숨긴다):
/// - 거리 기준으로 삼을 수 있는 샘플이 2개 미만 (실내 러닝·수동 입력·경로 유실)
/// - 총 이동 거리가 [minSplittableMeters] 미만
List<LapSplit> computeLapSplits(RunRecord record) {
  final basis = _DistanceBasis.from(record.samples);
  if (basis == null) return const [];

  final total = basis.totalMeters;
  if (total < minSplittableMeters) return const [];

  final splits = <LapSplit>[];
  final fullLapCount = (total / fullLapMeters).floor();

  var prevSeconds = 0;
  var prevDistance = 0.0;

  // 경계 시각을 먼저 초로 반올림한 뒤 차분한다. 그래야 표에 찍히는 시간과
  // 그 시간으로 계산한 페이스가 서로 어긋나지 않는다.
  for (var lap = 1; lap <= fullLapCount; lap++) {
    final boundary = lap * fullLapMeters;
    final seconds = basis.secondsAt(boundary);
    if (seconds == null) break; // 서버와 동일: 도달하지 못한 랩은 방출하지 않음
    final rounded = seconds.round();

    splits.add(
      _split(
        index: lap,
        basis: basis,
        fromMeters: prevDistance,
        toMeters: boundary,
        durationSeconds: rounded - prevSeconds,
        isPartial: false,
      ),
    );
    prevSeconds = rounded;
    prevDistance = boundary;
  }

  final remainder = total - prevDistance;
  if (remainder >= minPartialLapMeters) {
    splits.add(
      _split(
        index: fullLapCount + 1,
        basis: basis,
        fromMeters: prevDistance,
        toMeters: total,
        durationSeconds: basis.totalSeconds - prevSeconds,
        isPartial: true,
      ),
    );
  }

  return splits;
}

LapSplit _split({
  required int index,
  required _DistanceBasis basis,
  required double fromMeters,
  required double toMeters,
  required int durationSeconds,
  required bool isPartial,
}) {
  final distance = toMeters - fromMeters;
  final duration = durationSeconds < 0 ? 0 : durationSeconds;
  return LapSplit(
    index: index,
    distanceMeters: distance,
    durationSeconds: duration,
    paceSecPerKm:
        distance <= 0 || duration <= 0 ? 0.0 : duration / (distance / fullLapMeters),
    isPartial: isPartial,
    // 심박은 구간 안에서 실제로 측정된 값만 평균한다 — 경계 샘플은 앞
    // 구간의 것이다.
    avgHeartRateBpm:
        _averageHeartRate(basis.samplesInRange(fromMeters, toMeters)),
    // 고도는 **차분**이라 기준점이 하나 더 필요하다. 구간 시작 샘플을 빼면
    // 매 랩의 첫 오르막이 통째로 사라진다.
    elevationGainMeters: _elevationGain(
      basis.samplesInRange(fromMeters, toMeters, includeAnchor: true),
    ),
  );
}

/// 샘플 목록을 "시간 오름차순 + 누적거리 단조 증가"로 정규화한 것.
///
/// 서버는 `cumulative_distance_meters`만 본다. 클래스로 감싼 이유는 거리
/// 원천이 둘(엔진 누적값 / 좌표 Haversine)이라, 그 선택을 한 곳에 가두고
/// 나머지 계산이 원천을 몰라도 되게 하기 위해서다.
class _DistanceBasis {
  _DistanceBasis._(this._points, this._cumulative, this._startTime);

  final List<RunSample> _points;
  final List<double> _cumulative;
  final DateTime _startTime;

  double get totalMeters => _cumulative.last;

  int get totalSeconds =>
      _points.last.timestamp.difference(_startTime).inSeconds;

  /// 사용할 수 있는 거리 원천이 없으면 null.
  static _DistanceBasis? from(List<RunSample> samples) {
    // 1순위: 서버와 같은 입력 — 엔진이 채운 누적거리.
    final withCumulative = _timeOrdered(
      samples.where((s) => s.cumulativeDistanceMeters != null),
    );
    if (withCumulative.length >= 2) {
      final raw = withCumulative
          .map((s) => s.cumulativeDistanceMeters!)
          .toList(growable: false);
      return _DistanceBasis._(
        withCumulative,
        _monotonic(raw),
        withCumulative.first.timestamp,
      );
    }

    // 2순위: 좌표로 재계산 (RunSample.cumulativeDistanceMeters 주석의 계약).
    final withCoords = _timeOrdered(
      samples.where((s) => s.latitude != null && s.longitude != null),
    );
    if (withCoords.length < 2) return null;
    final cumulative = <double>[0];
    for (var i = 1; i < withCoords.length; i++) {
      cumulative.add(
        cumulative.last +
            haversineMeters(
              withCoords[i - 1].latitude!,
              withCoords[i - 1].longitude!,
              withCoords[i].latitude!,
              withCoords[i].longitude!,
            ),
      );
    }
    return _DistanceBasis._(withCoords, cumulative, withCoords.first.timestamp);
  }

  /// 누적거리 [targetMeters] 지점의 통과 시각(세션 시작부터의 초).
  /// 서버 `_run_time_at_distance`와 같은 분기를 쓴다.
  double? secondsAt(double targetMeters) {
    if (targetMeters <= 0) return 0;
    for (var i = 0; i < _points.length; i++) {
      if (_cumulative[i] < targetMeters) continue;
      final tEnd = _points[i].timestamp.difference(_startTime).inMilliseconds;
      if (i == 0) return tEnd / 1000.0;
      final segSpan = _cumulative[i] - _cumulative[i - 1];
      if (segSpan <= 0) return tEnd / 1000.0;
      final tStart =
          _points[i - 1].timestamp.difference(_startTime).inMilliseconds;
      final ratio = (targetMeters - _cumulative[i - 1]) / segSpan;
      return (tStart + (tEnd - tStart) * ratio) / 1000.0;
    }
    return null; // 샘플이 그 거리에 도달하지 못했다.
  }

  /// 누적거리 `(fromMeters, toMeters]` 구간에 속하는 샘플.
  ///
  /// [includeAnchor]가 true면 구간 **직전** 샘플 하나를 맨 앞에 붙인다.
  /// 차분으로 계산하는 지표(고도 게인)는 기준점이 없으면 구간의 첫 변화량을
  /// 잃는다.
  List<RunSample> samplesInRange(
    double fromMeters,
    double toMeters, {
    bool includeAnchor = false,
  }) {
    final result = <RunSample>[];
    int? anchor;
    for (var i = 0; i < _points.length; i++) {
      if (_cumulative[i] <= fromMeters) {
        anchor = i;
        continue;
      }
      if (_cumulative[i] > toMeters) break;
      if (includeAnchor && result.isEmpty && anchor != null) {
        result.add(_points[anchor]);
      }
      result.add(_points[i]);
    }
    return result;
  }

  /// 시각이 **엄격히 증가**하는 샘플만 남긴다. 같은 초의 중복 샘플이 섞이면
  /// 보간 분모가 0이 되고, 역행 샘플은 누적거리를 되감는다.
  static List<RunSample> _timeOrdered(Iterable<RunSample> samples) {
    final result = <RunSample>[];
    DateTime? last;
    for (final s in samples) {
      if (last != null && !s.timestamp.isAfter(last)) continue;
      result.add(s);
      last = s.timestamp;
    }
    return result;
  }

  /// 누적거리를 비감소로 강제한다 — 보간 루프가 단조성을 전제한다.
  static List<double> _monotonic(List<double> raw) {
    final result = <double>[];
    var running = double.negativeInfinity;
    for (final v in raw) {
      running = v > running ? v : running;
      result.add(running);
    }
    // 첫 샘플이 0m가 아니어도 그대로 둔다 — 서버도 원본 누적값을 쓴다.
    return result;
  }
}

int? _averageHeartRate(List<RunSample> samples) {
  final values = samples
      .map((s) => s.heartRateBpm)
      .whereType<int>()
      .toList(growable: false);
  if (values.isEmpty) return null;
  return (values.reduce((a, b) => a + b) / values.length).round();
}

double? _elevationGain(List<RunSample> samples) {
  final values = samples
      .map((s) => s.altitudeMeters)
      .whereType<double>()
      .toList(growable: false);
  if (values.length < 2) return null;
  var gain = 0.0;
  for (var i = 1; i < values.length; i++) {
    final delta = values[i] - values[i - 1];
    if (delta > 0) gain += delta;
  }
  return gain;
}
