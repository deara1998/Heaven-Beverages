import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:heaven_beverages/models/attendance_log_entry.dart';
import 'package:heaven_beverages/models/user_session.dart';
import 'package:heaven_beverages/pages/login_page.dart';
import 'package:heaven_beverages/services/api_client.dart';
import 'package:heaven_beverages/services/attendance_service.dart';
import 'package:heaven_beverages/services/background_tracking_service.dart';
import 'package:heaven_beverages/services/location_service.dart';
import 'package:heaven_beverages/services/session_storage.dart';
import 'package:intl/intl.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.session});

  final UserSession session;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  final _attendanceService = AttendanceService();
  final _locationService = LocationService();
  final _sessionStorage = SessionStorage();
  final _timeFormat = DateFormat('hh:mm a');
  final _dateTimeFormat = DateFormat('dd MMM yyyy, hh:mm a');

  GoogleMapController? _mapController;
  bool _isPunchedIn = false;
  bool _isBusy = false;
  bool _isTracking = false;
  DateTime? _punchInTime;
  DateTime? _lastSyncTime;
  LocationSnapshot? _currentLocation;
  final List<AttendanceLogEntry> _activityLog = [];
  StreamSubscription<Map<String, dynamic>?>? _syncSubscription;
  bool _isSendingTrackLog = false;

  static const _trackInterval = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _syncSubscription =
          BackgroundTrackingService.syncUpdates().listen(_handleBackgroundSync);
    }
    _restoreState();
    _loadLastSyncFromStorage();
    _refreshLocation(showLoader: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadLastSyncFromStorage();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncSubscription?.cancel();
    _mapController?.dispose();
    _locationService.dispose();
    _attendanceService.dispose();
    super.dispose();
  }

  Future<void> _loadLastSyncFromStorage() async {
    final stored = await _sessionStorage.loadLastSync();
    if (!mounted || stored == null) return;

    setState(() {
      _lastSyncTime = stored.syncTime;
      _currentLocation = LocationSnapshot(
        latitude: stored.latitude,
        longitude: stored.longitude,
        speedKmh: stored.speedKmh,
        batteryPercentage: stored.batteryPercentage,
      );
    });
    await _moveMapCamera(stored.latitude, stored.longitude);
  }

  void _handleBackgroundSync(Map<String, dynamic>? event) {
    if (!mounted || event == null) return;

    final latitude = event['latitude'];
    final longitude = event['longitude'];
    if (latitude is num && longitude is num) {
      final snapshot = LocationSnapshot(
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
        speedKmh: event['speedKmh']?.toString() ?? '0',
        batteryPercentage: event['batteryPercentage']?.toString() ?? '0',
      );
      final syncTimeRaw = event['syncTime']?.toString();
      setState(() {
        _currentLocation = snapshot;
        _lastSyncTime =
            syncTimeRaw == null ? DateTime.now() : DateTime.tryParse(syncTimeRaw);
      });
      _moveMapCamera(snapshot.latitude, snapshot.longitude);
      _addLog(
        action: (event['success'] as bool? ?? false) ? 'Track Log' : 'Track Log Failed',
        snapshot: snapshot,
        message: event['message']?.toString(),
        success: event['success'] as bool? ?? false,
      );
    } else if (event['message'] != null) {
      _addLog(
        action: 'Track Log Failed',
        snapshot: _currentLocation ??
            const LocationSnapshot(
              latitude: 0,
              longitude: 0,
              speedKmh: '0',
              batteryPercentage: '0',
            ),
        message: event['message'].toString(),
        success: false,
      );
    }
  }

  Future<void> _restoreState() async {
    final stored = await _sessionStorage.loadPunchState(widget.session.userId);
    if (!mounted || stored == null) return;

    setState(() {
      _isPunchedIn = true;
      _punchInTime = stored.punchInTime;
      _isTracking = true;
    });
    await _startTracking();
  }

  Future<void> _startTracking({bool callTrackLogNow = false}) async {
    if (kIsWeb) {
      if (callTrackLogNow && _currentLocation != null) {
        await _sendTrackLogFromForeground(_currentLocation!);
      }
      _locationService.startPeriodicTracking(
        interval: _trackInterval,
        onTick: _sendTrackLogFromForeground,
        onError: (error) {
          if (!mounted) return;
          _addLog(
            action: 'Track Log Failed',
            snapshot: _currentLocation ??
                const LocationSnapshot(
                  latitude: 0,
                  longitude: 0,
                  speedKmh: '0',
                  batteryPercentage: '0',
                ),
            message: error.toString(),
            success: false,
          );
        },
      );
      return;
    }
    await BackgroundTrackingService.start(
      widget.session.userId,
      callTrackLogNow: callTrackLogNow,
    );
  }

  Future<AttendanceResult> _callTrackLog(LocationSnapshot snapshot) {
    return _attendanceService.trackLogLocation(
      userId: widget.session.userId,
      latitude: snapshot.latitude.toString(),
      longitude: snapshot.longitude.toString(),
    );
  }

  Future<void> _recordTrackLog(
    LocationSnapshot snapshot, {
    required AttendanceResult result,
  }) async {
    if (!mounted) return;
    setState(() {
      _currentLocation = snapshot;
      _lastSyncTime = DateTime.now();
    });
    await _moveMapCamera(snapshot.latitude, snapshot.longitude);
    _addLog(
      action: 'Track Log',
      snapshot: snapshot,
      message: result.message ?? 'Location synced',
      success: result.isSuccess,
    );
  }

  Future<void> _stopTracking() async {
    _locationService.stopPeriodicTracking();
    if (!kIsWeb) {
      await BackgroundTrackingService.stop();
    }
  }

  Future<void> _sendTrackLogFromForeground(LocationSnapshot snapshot) async {
    if (!_isPunchedIn || _isSendingTrackLog) return;
    _isSendingTrackLog = true;

    try {
      final result = await _callTrackLog(snapshot);
      await _recordTrackLog(snapshot, result: result);
    } catch (error) {
      if (!mounted) return;
      _addLog(
        action: 'Track Log Failed',
        snapshot: snapshot,
        message: _connectionErrorMessage(error),
        success: false,
      );
    } finally {
      _isSendingTrackLog = false;
    }
  }

  Future<void> _refreshLocation({bool showLoader = true}) async {
    if (showLoader) setState(() => _isBusy = true);
    try {
      final snapshot = await _locationService.getCurrentSnapshot();
      if (!mounted) return;
      setState(() => _currentLocation = snapshot);
      await _moveMapCamera(snapshot.latitude, snapshot.longitude);
    } on LocationException catch (error) {
      _showMessage(error.message, isError: true);
    } catch (_) {
      _showMessage('Unable to fetch location.', isError: true);
    } finally {
      if (mounted && showLoader) setState(() => _isBusy = false);
    }
  }

  Future<void> _handlePunchIn() async {
    if (_isBusy) return;
    if (_isPunchedIn) {
      _showMessage('You are already ON DUTY. Use Punch Out to end your shift.');
      return;
    }
    setState(() => _isBusy = true);

    try {
      final snapshot = await _locationService.getCurrentSnapshot();
      final result = await _attendanceService.punchIn(
        userId: widget.session.userId,
        latitude: snapshot.latitude.toString(),
        longitude: snapshot.longitude.toString(),
      );

      if (!result.isSuccess) {
        throw AttendanceException(result.message ?? result.raw);
      }

      final punchInTime = DateTime.now();
      await _sessionStorage.savePunchIn(
        userId: widget.session.userId,
        punchInTime: punchInTime,
      );

      if (!mounted) return;
      setState(() {
        _isPunchedIn = true;
        _punchInTime = punchInTime;
        _currentLocation = snapshot;
        _isTracking = true;
      });

      _addLog(
        action: 'Punch In',
        snapshot: snapshot,
        message: result.message ?? 'Punched in successfully',
      );

      final trackResult = await _callTrackLog(snapshot);
      await _recordTrackLog(snapshot, result: trackResult);

      await _moveMapCamera(snapshot.latitude, snapshot.longitude);
      await _startTracking(callTrackLogNow: false);
      _showMessage(result.message ?? 'Punch in successful');
    } on AttendanceException catch (error) {
      _showMessage(error.message, isError: true);
    } on LocationException catch (error) {
      _showMessage(error.message, isError: true);
    } catch (error) {
      _showMessage(_connectionErrorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handlePunchOut() async {
    if (_isBusy) return;
    if (!_isPunchedIn) {
      _showMessage('You are OFF DUTY. Use Punch In to start your shift.');
      return;
    }
    setState(() => _isBusy = true);

    try {
      await _stopTracking();
      final snapshot = await _locationService.getCurrentSnapshot();
      final result = await _attendanceService.punchOut(
        userId: widget.session.userId,
        latitude: snapshot.latitude.toString(),
        longitude: snapshot.longitude.toString(),
      );

      if (!result.isSuccess) {
        throw AttendanceException(result.message ?? result.raw);
      }

      await _sessionStorage.clearPunchIn();

      if (!mounted) return;
      setState(() {
        _isPunchedIn = false;
        _isTracking = false;
        _punchInTime = null;
        _currentLocation = snapshot;
      });

      _addLog(
        action: 'Punch Out',
        snapshot: snapshot,
        message: result.message ?? 'Punched out successfully',
      );

      final trackResult = await _callTrackLog(snapshot);
      await _recordTrackLog(snapshot, result: trackResult);

      await _moveMapCamera(snapshot.latitude, snapshot.longitude);
      _showMessage(result.message ?? 'Punch out successful');
    } on AttendanceException catch (error) {
      if (_isPunchedIn) await _startTracking();
      _showMessage(error.message, isError: true);
    } on LocationException catch (error) {
      if (_isPunchedIn) await _startTracking();
      _showMessage(error.message, isError: true);
    } catch (error) {
      if (_isPunchedIn) await _startTracking();
      _showMessage(_connectionErrorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _logout() async {
    if (_isPunchedIn) {
      _showMessage('Please punch out before logging out.', isError: true);
      return;
    }

    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: Text('Logout from ${widget.session.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (shouldLogout != true || !mounted) return;

    await _stopTracking();
    await _sessionStorage.clearUserSession();
    await _sessionStorage.clearPunchIn();

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  Future<void> _moveMapCamera(double latitude, double longitude) async {
    final controller = _mapController;
    if (controller == null) return;
    await controller.animateCamera(
      CameraUpdate.newLatLng(LatLng(latitude, longitude)),
    );
  }

  void _addLog({
    required String action,
    required LocationSnapshot snapshot,
    String? message,
    bool success = true,
  }) {
    setState(() {
      _activityLog.insert(
        0,
        AttendanceLogEntry(
          time: DateTime.now(),
          action: action,
          latitude: snapshot.latitude,
          longitude: snapshot.longitude,
          message: message,
          success: success,
        ),
      );
      if (_activityLog.length > 20) {
        _activityLog.removeRange(20, _activityLog.length);
      }
    });
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  String _connectionErrorMessage(Object error) {
    if (error is ApiTimeoutException) {
      return error.message;
    }
    if (error is ApiNetworkException) {
      return error.message;
    }
    final errorText = error.toString();
    if (errorText.contains('TimeoutException') || errorText.contains('timed out')) {
      return 'Server took too long to respond. Please try again.';
    }
    if (kIsWeb && errorText.contains('Failed to fetch')) {
      return 'Browser blocked the API (CORS). Use .\\scripts\\run_web.ps1 '
          'or run on Windows/Android.';
    }
    return 'Unable to connect. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final location = _currentLocation;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('Attendance Dashboard'),
        actions: [
          IconButton(
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshLocation(showLoader: false),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(
              name: widget.session.displayName,
              mobileNo: widget.session.mobileNo,
              isPunchedIn: _isPunchedIn,
              punchInTime: _punchInTime,
              isTracking: _isTracking,
              lastSyncTime: _lastSyncTime,
              timeFormat: _timeFormat,
              dateTimeFormat: _dateTimeFormat,
            ),
            const SizedBox(height: 16),
            _MapCard(
              latitude: location?.latitude,
              longitude: location?.longitude,
              isTracking: _isTracking,
              onMapCreated: (controller) => _mapController = controller,
            ),
            const SizedBox(height: 16),
            _LocationInfoCard(
              latitude: location?.latitude,
              longitude: location?.longitude,
              speedKmh: location?.speedKmh,
              batteryPercentage: location?.batteryPercentage,
              lastSyncTime: _lastSyncTime,
              dateTimeFormat: _dateTimeFormat,
              onRefresh: _isBusy ? null : () => _refreshLocation(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isBusy ? null : _handlePunchIn,
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Punch In'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _isPunchedIn
                          ? Colors.green.shade400
                          : Colors.green.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isBusy ? null : _handlePunchOut,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Punch Out'),
                    style: FilledButton.styleFrom(
                      backgroundColor: !_isPunchedIn
                          ? Colors.orange.shade400
                          : Colors.orange.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
            if (_isBusy) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            const SizedBox(height: 20),
            Text(
              'Activity Log',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (_activityLog.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _isPunchedIn
                        ? 'Tracking will log your location every 20 seconds.'
                        : 'Punch in to start attendance and live location tracking.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              ..._activityLog.map(
                (entry) => _ActivityTile(
                  entry: entry,
                  dateTimeFormat: _dateTimeFormat,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.name,
    required this.mobileNo,
    required this.isPunchedIn,
    required this.punchInTime,
    required this.isTracking,
    required this.lastSyncTime,
    required this.timeFormat,
    required this.dateTimeFormat,
  });

  final String name;
  final String mobileNo;
  final bool isPunchedIn;
  final DateTime? punchInTime;
  final bool isTracking;
  final DateTime? lastSyncTime;
  final DateFormat timeFormat;
  final DateFormat dateTimeFormat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = isPunchedIn ? Colors.green.shade700 : Colors.grey.shade700;

    return Card(
      elevation: 0,
      color: colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: colorScheme.primary,
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: colorScheme.onPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        mobileNo,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isPunchedIn ? 'ON DUTY' : 'OFF DUTY',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (isPunchedIn && punchInTime != null)
              Text('Punched in at ${timeFormat.format(punchInTime!)}'),
            if (isTracking)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.gps_fixed, size: 18, color: Colors.green.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        lastSyncTime == null
                            ? 'Live tracking active • every 20 sec'
                            : 'Live tracking • last sync ${dateTimeFormat.format(lastSyncTime!)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.latitude,
    required this.longitude,
    required this.isTracking,
    required this.onMapCreated,
  });

  final double? latitude;
  final double? longitude;
  final bool isTracking;
  final ValueChanged<GoogleMapController> onMapCreated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLocation = latitude != null && longitude != null;
    final latLng = hasLocation ? LatLng(latitude!, longitude!) : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(Icons.map_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Live Location',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (isTracking)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Tracking',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.green.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 240,
            child: hasLocation && !kIsWeb
                ? GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: latLng!,
                      zoom: 16,
                    ),
                    markers: {
                      Marker(
                        markerId: const MarkerId('employee'),
                        position: latLng,
                      ),
                    },
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    zoomControlsEnabled: false,
                    onMapCreated: onMapCreated,
                  )
                : Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 48,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          hasLocation
                              ? 'Lat: ${latitude!.toStringAsFixed(6)}\nLng: ${longitude!.toStringAsFixed(6)}'
                              : 'Waiting for GPS location...',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (kIsWeb)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Map view works best on Android/iOS.\n'
                              'Web shows coordinates + API tracking.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LocationInfoCard extends StatelessWidget {
  const _LocationInfoCard({
    required this.latitude,
    required this.longitude,
    required this.speedKmh,
    required this.batteryPercentage,
    required this.lastSyncTime,
    required this.dateTimeFormat,
    required this.onRefresh,
  });

  final double? latitude;
  final double? longitude;
  final String? speedKmh;
  final String? batteryPercentage;
  final DateTime? lastSyncTime;
  final DateFormat dateTimeFormat;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _InfoRow(
              icon: Icons.my_location,
              label: 'Latitude',
              value: latitude?.toStringAsFixed(6) ?? '--',
            ),
            _InfoRow(
              icon: Icons.explore_outlined,
              label: 'Longitude',
              value: longitude?.toStringAsFixed(6) ?? '--',
            ),
            _InfoRow(
              icon: Icons.speed,
              label: 'Speed',
              value: speedKmh == null ? '--' : '$speedKmh km/h',
            ),
            _InfoRow(
              icon: Icons.battery_std_outlined,
              label: 'Battery',
              value: batteryPercentage == null ? '--' : '$batteryPercentage%',
            ),
            _InfoRow(
              icon: Icons.sync,
              label: 'Last API Sync',
              value: lastSyncTime == null
                  ? 'Not synced yet'
                  : dateTimeFormat.format(lastSyncTime!),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh Location'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.entry,
    required this.dateTimeFormat,
  });

  final AttendanceLogEntry entry;
  final DateFormat dateTimeFormat;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: entry.success
              ? colorScheme.primaryContainer
              : colorScheme.errorContainer,
          child: Icon(
            entry.success ? Icons.check : Icons.error_outline,
            color: entry.success
                ? colorScheme.onPrimaryContainer
                : colorScheme.onErrorContainer,
          ),
        ),
        title: Text(entry.action),
        subtitle: Text(
          '${dateTimeFormat.format(entry.time)}\n'
          'Lat ${entry.latitude.toStringAsFixed(5)}, '
          'Lng ${entry.longitude.toStringAsFixed(5)}'
          '${entry.message == null ? '' : '\n${entry.message}'}',
        ),
        isThreeLine: entry.message != null,
      ),
    );
  }
}
