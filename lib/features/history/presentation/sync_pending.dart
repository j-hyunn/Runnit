import '../../../models/models.dart';

/// 아직 서버에 올라가지 않은 **완료** 러닝인가.
///
/// ARCHITECTURE §9.1 — 오프라인으로 시즌·주 경계를 넘겨 지각 업로드된 기록은
/// 마감된 과거 구간에 소급 반영되지 않는다(정책). 그 손실을 사용자가 사후에
/// 알게 되는 대신 **업로드 전에** 알 수 있도록, 상세 화면 배너와 목록 칩이
/// 같은 이 술어를 쓴다.
///
/// `recording`/`paused`(진행 중)와 `discarded`(버려진 세션)는 애초에 업로드
/// 대상이 아니므로 제외한다 — 그 행들은 항상 `synced`가 아니라서 조건을
/// 상태로 좁히지 않으면 화면 전체가 "동기화 대기"로 뒤덮인다.
/// [syncStatus]를 넘기면 [record]의 값 대신 그것으로 판정한다 — 상세 화면이
/// 단발 조회 스냅샷 대신 `runSyncStatusProvider`의 실시간 값을 먹이는 통로다
/// (조회 후 업로드가 끝나면 배너가 그 자리에서 사라져야 한다).
bool isSyncPending(RunRecord record, {SyncStatus? syncStatus}) =>
    record.status == RunStatus.completed &&
    (syncStatus ?? record.syncStatus) != SyncStatus.synced;
