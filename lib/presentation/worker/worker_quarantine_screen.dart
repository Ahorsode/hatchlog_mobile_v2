import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/hatchlog_api_client.dart';
import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
import '../../features/auth/data/supabase_remote_api.dart';
import '../../features/livestock/data/livestock_models.dart';
import '../../features/livestock/data/livestock_repository.dart';
import '../../features/livestock/services/livestock_service.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../livestock/quarantine_actions_sheet.dart';
import '../mortality/mortality_quick_add_sheet.dart';
import 'widgets/quick_add_batch_grid.dart';

class WorkerQuarantineScreen extends StatefulWidget {
  const WorkerQuarantineScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    required this.inputSink,
    required this.batches,
    required this.canEdit,
    this.remoteApi,
    this.hatchlogApi,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final WorkerInputSink inputSink;
  final List<BatchSummary> batches;
  final bool canEdit;
  final SupabaseRemoteApi? remoteApi;
  final HatchlogApiClient? hatchlogApi;

  @override
  State<WorkerQuarantineScreen> createState() => _WorkerQuarantineScreenState();
}

class _WorkerQuarantineScreenState extends State<WorkerQuarantineScreen> {
  static const _accent = Color(0xffb45309);

  final _roomNameController = TextEditingController();
  final _roomCapacityController = TextEditingController();
  final _isolationCounts = <String, TextEditingController>{};

  StreamSubscription<void>? _subscription;
  late final LivestockService _livestockService;
  List<Map<String, Object?>> _rooms = const [];
  var _creatingRoom = false;
  var _actionBatchId = '';

  List<BatchSummary> get _activeBatches =>
      widget.batches.where((batch) => batch.isActive).toList(growable: false);

  List<BatchSummary> get _isolatedBatches => widget.batches
      .where((batch) => batch.isolationCount > 0)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _livestockService = LivestockService(
      repository: LivestockRepository(widget.localDatabase),
      remoteApi: widget.remoteApi,
      hatchlogApi: widget.hatchlogApi,
    );
    _subscription = widget.localDatabase
        .watchTables(const ['isolation_rooms', 'batches', 'quarantine', 'mortality'])
        .listen((_) => _loadRooms());
    _loadRooms();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _roomNameController.dispose();
    _roomCapacityController.dispose();
    for (final controller in _isolationCounts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _countControllerFor(String batchId, int maxCount) {
    return _isolationCounts.putIfAbsent(
      batchId,
      () => TextEditingController(
        text: maxCount > 0 ? maxCount.toString() : '',
      ),
    );
  }

  Future<void> _loadRooms() async {
    final rows = await widget.localDatabase.rawLocalQuery(
      '''
      select id, name, capacity
      from isolation_rooms
      where farm_id = ?
      order by name asc
      ''',
      [widget.currentUser.activeFarmId],
    );
    if (!mounted) {
      return;
    }
    setState(() => _rooms = rows);
  }

  Future<void> _openSickLog(BatchSummary batch) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return MortalityQuickAddSheet(
          currentUser: widget.currentUser,
          batch: batch,
          inputSink: widget.inputSink,
          localDatabase: widget.localDatabase,
          defaultHealthType: MortalityHealthType.sick,
        );
      },
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sick birds logged into quarantine.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _createRoom() async {
    if (_creatingRoom) {
      return;
    }
    final name = _roomNameController.text.trim();
    final capacity = int.tryParse(_roomCapacityController.text.trim()) ?? -1;
    if (name.isEmpty) {
      _showMessage('Room name is required');
      return;
    }
    if (capacity < 0) {
      _showMessage('Capacity must be zero or greater');
      return;
    }

    setState(() => _creatingRoom = true);
    try {
      final roomId = 'room_${DateTime.now().microsecondsSinceEpoch}';
      await widget.localDatabase.insertLocalRecord('isolation_rooms', {
        'id': roomId,
        'farm_id': widget.currentUser.activeFarmId,
        'name': name,
        'capacity': capacity,
        'user_id': widget.currentUser.id,
        'updated_at': DateTime.now().toIso8601String(),
      });

      final nest = widget.hatchlogApi;
      if (nest != null && nest.isConfigured) {
        try {
          await nest.createIsolationRoom({
            'farm_id': widget.currentUser.activeFarmId,
            'name': name,
            'capacity': capacity < 1 ? 1 : capacity,
          });
        } on Object catch (error) {
          if (mounted) {
            _showMessage('Saved locally. Cloud sync pending: $error');
          }
        }
      }

      _roomNameController.clear();
      _roomCapacityController.clear();
      await _loadRooms();
      if (mounted) {
        _showMessage('Isolation room created');
      }
    } finally {
      if (mounted) {
        setState(() => _creatingRoom = false);
      }
    }
  }

  Future<void> _handleIsolationAction(
    BatchSummary batch, {
    required bool recover,
  }) async {
    final controller = _countControllerFor(batch.id, batch.isolationCount);
    final count = int.tryParse(controller.text.trim()) ?? batch.isolationCount;
    if (count <= 0 || count > batch.isolationCount) {
      _showMessage('Enter a count between 1 and ${batch.isolationCount}');
      return;
    }

    setState(() => _actionBatchId = '${batch.id}-${recover ? 'recover' : 'dead'}');
    try {
      final result = recover
          ? await _livestockService.recoverFromIsolation(
              user: widget.currentUser,
              batchId: batch.id,
              count: count,
            )
          : await _livestockService.logMortalityInIsolation(
              user: widget.currentUser,
              batchId: batch.id,
              count: count,
              reason: 'Resolved in Quarantine',
            );
      if (!mounted) {
        return;
      }
      if (result.success) {
        controller.clear();
        _showMessage(
          recover
              ? '$count birds recovered from isolation'
              : '$count mortality logs recorded',
        );
      } else {
        _showMessage(result.error ?? 'Operation failed');
      }
    } finally {
      if (mounted) {
        setState(() => _actionBatchId = '');
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Quarantine & Isolation'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.coronavirus_outlined, color: _accent, size: 28),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Quarantine & Isolation',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Manage isolated livestock and dedicated recovery facilities.',
                  style: TextStyle(
                    color: Color(0xff66736c),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (widget.canEdit) ...[
            const SizedBox(height: 14),
            _SectionCard(
              title: 'Quick Sick Logger',
              subtitle: 'Tap a batch to log sick birds into quarantine.',
              child: QuickAddBatchGrid(
                batches: _activeBatches,
                accentColor: _accent,
                icon: Icons.healing_outlined,
                emptyMessage: 'No active batches are cached. Sync first.',
                onTapAdd: _openSickLog,
              ),
            ),
          ],
          const SizedBox(height: 14),
          _SectionCard(
            title: 'Isolation Rooms',
            subtitle: 'Configure dedicated housing for sick or quarantined birds.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.canEdit) ...[
                  TextField(
                    controller: _roomNameController,
                    decoration: const InputDecoration(
                      labelText: 'Room Name',
                      hintText: 'e.g. Infirmary A',
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _roomCapacityController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Capacity (birds)',
                      hintText: 'e.g. 50',
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _creatingRoom ? null : _createRoom,
                    icon: _creatingRoom
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add),
                    label: const Text('Add Room'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_rooms.isEmpty)
                  const _EmptyRoomsState()
                else
                  for (final room in _rooms) ...[
                    _IsolationRoomCard(room: room),
                    const SizedBox(height: 8),
                  ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: 'Active Isolation Management',
            subtitle: 'Recover birds or log deaths for batches in quarantine.',
            child: _isolatedBatches.isEmpty
                ? const _ZeroQuarantineState()
                : Column(
                    children: [
                      for (final batch in _isolatedBatches) ...[
                        _IsolationBatchCard(
                          batch: batch,
                          countController: _countControllerFor(
                            batch.id,
                            batch.isolationCount,
                          ),
                          isRecovering:
                              _actionBatchId == '${batch.id}-recover',
                          isLoggingMortality:
                              _actionBatchId == '${batch.id}-dead',
                          onRecover: widget.canEdit
                              ? () => _handleIsolationAction(
                                    batch,
                                    recover: true,
                                  )
                              : null,
                          onMortality: widget.canEdit
                              ? () => _handleIsolationAction(
                                    batch,
                                    recover: false,
                                  )
                              : null,
                          onOpenSheet: widget.canEdit
                              ? () => _openIsolationSheet(batch)
                              : null,
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openIsolationSheet(BatchSummary batch) async {
    final record = LivestockBatchRecord(
      id: batch.id,
      farmId: widget.currentUser.activeFarmId,
      batchName: batch.batchLabel,
      breedType: '',
      type: batch.livestockType,
      houseId: batch.houseId,
      houseName: batch.houseLabel,
      currentCount: batch.currentCount,
      isolationCount: batch.isolationCount,
      initialCount: batch.currentCount + batch.isolationCount,
      status: batch.status,
      arrivalDate: DateTime.now(),
    );
    final result = await showModalBottomSheet<LivestockOperationResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return QuarantineActionsSheet(
          batch: record,
          onRecover: (count) => _livestockService.recoverFromIsolation(
            user: widget.currentUser,
            batchId: batch.id,
            count: count,
          ),
          onLogMortality: (count) => _livestockService.logMortalityInIsolation(
            user: widget.currentUser,
            batchId: batch.id,
            count: count,
            reason: 'Resolved in Quarantine',
          ),
        );
      },
    );
    if (result != null && result.success && mounted) {
      _showMessage('Isolation update saved');
    }
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    this.title,
    this.subtitle,
    required this.child,
  });

  final String? title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xffe2e8e4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: const TextStyle(
                  color: Color(0xff66736c),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 14),
          ],
          child,
        ],
      ),
    );
  }
}

class _IsolationRoomCard extends StatelessWidget {
  const _IsolationRoomCard({required this.room});

  final Map<String, Object?> room;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfff8faf7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xffe2e8e4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room['name']?.toString() ?? 'Isolation room',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  'Capacity: ${room['capacity'] ?? 0} birds',
                  style: const TextStyle(
                    color: Color(0xff66736c),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xfffff7ed),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'ACTIVE',
              style: TextStyle(
                color: Color(0xffb45309),
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IsolationBatchCard extends StatelessWidget {
  const _IsolationBatchCard({
    required this.batch,
    required this.countController,
    required this.isRecovering,
    required this.isLoggingMortality,
    this.onRecover,
    this.onMortality,
    this.onOpenSheet,
  });

  final BatchSummary batch;
  final TextEditingController countController;
  final bool isRecovering;
  final bool isLoggingMortality;
  final VoidCallback? onRecover;
  final VoidCallback? onMortality;
  final VoidCallback? onOpenSheet;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfff8faf7),
        borderRadius: BorderRadius.circular(12),
        border: const Border(
          left: BorderSide(color: Color(0xffb45309), width: 4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.coronavirus_outlined, color: Color(0xffb45309)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  batch.batchLabel,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (onOpenSheet != null)
                IconButton(
                  tooltip: 'More actions',
                  onPressed: onOpenSheet,
                  icon: const Icon(Icons.more_horiz),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xfffff7ed),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'IN QUARANTINE',
                  style: TextStyle(
                    color: Color(0xffb45309),
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '${batch.isolationCount} birds',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          if (onRecover != null || onMortality != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 72,
                  child: TextField(
                    controller: countController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      labelText: 'Count',
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isRecovering || isLoggingMortality
                        ? null
                        : onRecover,
                    icon: isRecovering
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Recover'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xff1f7a4d),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isRecovering || isLoggingMortality
                        ? null
                        : onMortality,
                    icon: isLoggingMortality
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.dangerous_outlined, size: 18),
                    label: const Text('Mortality'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xffb83b3b),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyRoomsState extends StatelessWidget {
  const _EmptyRoomsState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: const Color(0xfff8faf7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xffe2e8e4),
          style: BorderStyle.solid,
        ),
      ),
      child: const Column(
        children: [
          Icon(Icons.home_work_outlined, size: 40, color: Color(0xffb45309)),
          SizedBox(height: 8),
          Text(
            'No isolation rooms configured yet.',
            style: TextStyle(
              color: Color(0xff66736c),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ZeroQuarantineState extends StatelessWidget {
  const _ZeroQuarantineState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: const Color(0xfff8faf7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xffe2e8e4)),
      ),
      child: const Column(
        children: [
          Icon(Icons.check_circle_outline, size: 42, color: Color(0xff1f7a4d)),
          SizedBox(height: 8),
          Text(
            'Zero Quarantined Birds',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 4),
          Text(
            'Your entire livestock population is currently in active production houses.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xff66736c),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
