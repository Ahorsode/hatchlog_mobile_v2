import 'package:flutter/foundation.dart';

import '../api/hatchlog_api_client.dart';
import '../config/hatchlog_api_config.dart';
import '../storage/local_database.dart';
import 'license_status.dart';

class LicenseConfig {
  const LicenseConfig({
    required this.mode,
    required this.farmId,
    required this.userId,
    required this.hardwareId,
    required this.installedAt,
    required this.expiresAt,
    required this.lastUsed,
    required this.lastCloudCheckAt,
  });

  final String mode;
  final String? farmId;
  final String? userId;
  final String? hardwareId;
  final DateTime installedAt;
  final DateTime expiresAt;
  final DateTime lastUsed;
  final DateTime? lastCloudCheckAt;

  factory LicenseConfig.fromMap(Map<String, Object?> map) {
    return LicenseConfig(
      mode: map['mode'] as String,
      farmId: map['farm_id'] as String?,
      userId: map['user_id'] as String?,
      hardwareId: map['hardware_id'] as String?,
      installedAt: DateTime.parse(map['installed_at'] as String),
      expiresAt: DateTime.parse(map['expires_at'] as String),
      lastUsed: DateTime.parse(map['last_used'] as String),
      lastCloudCheckAt: map['last_cloud_check_at'] == null
          ? null
          : DateTime.parse(map['last_cloud_check_at'] as String),
    );
  }
}

class LicenseService {
  LicenseService(this._db);

  static const trialExhaustedErrorCode = 'TRIAL_EXHAUSTED';

  final LocalDatabase _db;

  Future<LicenseStatus> checkLicense() async {
    final config = await _loadConfig();
    if (config == null) {
      return LicenseStatus.firstLaunch;
    }

    final now = DateTime.now();

    if (config.mode == 'HARD_LOCKED') {
      return LicenseStatus.hardLocked;
    }

    if (now.isBefore(config.lastUsed.subtract(const Duration(minutes: 2)))) {
      return LicenseStatus.clockTampered;
    }

    if (now.isBefore(config.expiresAt)) {
      return LicenseStatus.valid;
    }

    final lastCloudCheckAt = config.lastCloudCheckAt;
    if (lastCloudCheckAt != null) {
      final daysSinceCheck = now.difference(lastCloudCheckAt).inDays;
      if (daysSinceCheck < 10) {
        return LicenseStatus.valid;
      }
    }

    final daysPastExpiry = now.difference(config.expiresAt).inDays;
    if (daysPastExpiry <= 5) {
      return LicenseStatus.softLocked;
    }

    await _setMode('HARD_LOCKED');
    return LicenseStatus.hardLocked;
  }

  Future<String?> initTrialFromCloud({
    required String userId,
    required String farmId,
    String hardwareId = '',
  }) async {
    try {
      final api = HatchlogApiClient(config: HatchlogApiConfig.load());
      if (!api.isConfigured) {
        return 'HatchLog API is not configured.';
      }
      final data = await api.getSubscriptionStatus(farmId);
      await applyFarmStatus(
        data,
        farmId: farmId,
        userId: userId,
        hardwareId: hardwareId,
      );
      if (data['status']?.toString() == 'locked') {
        return trialExhaustedErrorCode;
      }
      return null;
    } on Object catch (error) {
      debugPrint('[License] initTrialFromCloud error: $error');
      return 'Could not read farm subscription status.';
    }
  }

  Future<void> renewFromCloud([String? farmOrHardwareId]) async {
    try {
      final config = await _loadConfig();
      final farmId = (config?.farmId != null && config!.farmId!.isNotEmpty)
          ? config.farmId!
          : farmOrHardwareId;
      if (farmId == null || farmId.isEmpty) {
        return;
      }
      final api = HatchlogApiClient(config: HatchlogApiConfig.load());
      if (!api.isConfigured) {
        return;
      }
      final data = await api.getSubscriptionStatus(farmId);
      await applyFarmStatus(
        data,
        farmId: farmId,
        userId: config?.userId,
        hardwareId: config?.hardwareId ?? '',
      );
    } on Object {
      // Offline: keep local farm clock.
    }
  }

  Future<void> applyFarmStatus(
    Map<String, dynamic> data, {
    required String farmId,
    String? userId,
    String hardwareId = '',
  }) async {
    final now = DateTime.now();
    final status = data['status']?.toString() ?? 'locked';
    final periodEndsAt =
        DateTime.tryParse(data['periodEndsAt']?.toString() ?? '') ?? now;
    final mode = switch (status) {
      'paid' => 'CLOUD_ACTIVE',
      'trial' => 'CLOUD_TRIAL',
      _ => 'HARD_LOCKED',
    };
    final config = await _loadConfig();
    await _upsertConfig(
      mode: mode,
      farmId: farmId,
      userId: userId ?? config?.userId,
      hardwareId: hardwareId.isNotEmpty
          ? hardwareId
          : (config?.hardwareId ?? ''),
      installedAt: config?.installedAt ?? now,
      expiresAt: periodEndsAt,
      lastCloudCheckAt: now,
    );
  }

  Future<void> touchLastUsed() async {
    try {
      await _db.rawLocalUpdate('license_configs', {
        'last_used': DateTime.now().toIso8601String(),
      }, "id = 'singleton'");
    } on Object {
      // Missing table/config during early boot should never block data writes.
    }
  }

  Future<LicenseConfig?> getConfig() => _loadConfig();

  Future<LicenseConfig?> _loadConfig() async {
    final rows = await _db.rawLocalQuery(
      "select * from license_configs where id = 'singleton'",
    );
    if (rows.isEmpty) {
      return null;
    }
    return LicenseConfig.fromMap(rows.first);
  }

  Future<void> _upsertConfig({
    required String mode,
    required String? farmId,
    required String? userId,
    required String? hardwareId,
    required DateTime installedAt,
    required DateTime expiresAt,
    DateTime? lastCloudCheckAt,
  }) async {
    final now = DateTime.now();
    await _db.rawLocalInsertOrReplace('license_configs', {
      'id': 'singleton',
      'mode': mode,
      'farm_id': farmId,
      'user_id': userId,
      'hardware_id': hardwareId,
      'installed_at': installedAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
      'last_used': now.toIso8601String(),
      'last_cloud_check_at': lastCloudCheckAt?.toIso8601String(),
    });
  }

  Future<void> _setMode(String mode) async {
    await _db.rawLocalUpdate('license_configs', {
      'mode': mode,
    }, "id = 'singleton'");
  }
}
