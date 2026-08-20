import 'package:flutter_test/flutter_test.dart';

void main() {
  test('farm status maps to the same local expiry for every user', () {
    const periodEndsAt = '2026-09-19T12:00:00.000Z';
    final owner = _localClock(
      status: 'trial',
      periodEndsAt: periodEndsAt,
      userId: 'owner',
    );
    final worker = _localClock(
      status: 'trial',
      periodEndsAt: periodEndsAt,
      userId: 'worker',
    );

    expect(worker.expiresAt, owner.expiresAt);
    expect(owner.mode, 'CLOUD_TRIAL');
    expect(worker.mode, 'CLOUD_TRIAL');
  });
}

({String mode, DateTime expiresAt, String userId}) _localClock({
  required String status,
  required String periodEndsAt,
  required String userId,
}) {
  final mode = switch (status) {
    'paid' => 'CLOUD_ACTIVE',
    'trial' => 'CLOUD_TRIAL',
    _ => 'HARD_LOCKED',
  };
  return (
    mode: mode,
    expiresAt: DateTime.parse(periodEndsAt),
    userId: userId,
  );
}
