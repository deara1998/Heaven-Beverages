import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:heaven_beverages/models/attendance_log_entry.dart';
import 'package:heaven_beverages/models/track_point.dart';
import 'package:heaven_beverages/models/user_session.dart';
import 'package:heaven_beverages/pages/login_page.dart';
import 'package:heaven_beverages/services/api_client.dart';
import 'package:heaven_beverages/services/attendance_service.dart';
import 'package:heaven_beverages/services/location_service.dart';
import 'package:heaven_beverages/services/session_manager.dart';
import 'package:heaven_beverages/services/session_storage.dart';
import 'package:heaven_beverages/services/tracking_constants.dart';
import 'package:heaven_beverages/services/tracking_permissions.dart';
import 'package:heaven_beverages/theme/app_theme.dart';
import 'package:heaven_beverages/widgets/attendance_route_map.dart';
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
  final _sessionManager = SessionManager();
  final _dateTimeFormat = DateFormat('dd MMM yyyy, hh:mm a');

  bool _isPunchedIn = false;
  bool _isBusy = false;
  bool _isLoadingDashboard = true;
  String? _todayStatus;
  DateTime? _punchInTime;
  LocationSnapshot? _currentLocation;
  final List<AttendanceLogEntry> _activityLog = [];
  List<TrackPoint> _dayRoutePoints = [];
  final List<TrackPoint> _liveRoutePoints = [];
  bool _isSendingTrackLog = false;
  bool _foregroundTrackingActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_safeStartup());
    });
  }

  Future<void> _safeStartup() async {
    try {
      await _loadStaffDashboard();

      if (_isPunchedIn) {
        _scheduleForegroundTracking();
      }

      if (await TrackingPermissions.hasForegroundLocation()) {
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (!mounted) return;
          unawaited(_refreshLocation(showLoader: false));
        });
      }
    } catch (error, stackTrace) {
      debugPrint('[Dashboard] startup failed: $error');
      debugPrint('$stackTrace');
    } finally {
      if (mounted) {
        setState(() => _isLoadingDashboard = false);
      }
    }
  }

  void _scheduleForegroundTracking() {
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (!mounted || !_isPunchedIn) return;
      unawaited(_startTracking());
    });
  }

  String _todayTripDate() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _loadStaffDashboard({bool showLoader = false}) async {
    if (showLoader && mounted) {
      setState(() => _isLoadingDashboard = true);
    }

    try {
      final dashboard = await _attendanceService.staffDashboard(
        userId: widget.session.userId,
        tripDate: _todayTripDate(),
      );

      if (!dashboard.isSuccess) {
        debugPrint(
          '[Dashboard] staff_dashboard failed: ${dashboard.message ?? dashboard.raw}',
        );
        await _restoreStateFromLocal();
        return;
      }

      final isOnDuty = dashboard.isOnDuty;

      if (dashboard.isPunchedIn == null) {
        debugPrint('[Dashboard] staff_dashboard missing status, using local state');
        await _restoreStateFromLocal();
        return;
      }

      if (!mounted) return;
      setState(() => _todayStatus = dashboard.todayStatus);

      if (mounted) {
        _mergeApiRoutePoints(dashboard.dayTrackPoints);
      }

      await _applyAttendanceState(
        isPunchedIn: isOnDuty,
        punchInTime: dashboard.punchInTime,
      );
    } on AttendanceException catch (error) {
      debugPrint('[Dashboard] staff_dashboard error: ${error.message}');
      await _restoreStateFromLocal();
    } catch (error) {
      debugPrint('[Dashboard] staff_dashboard error: $error');
      await _restoreStateFromLocal();
    } finally {
      if (showLoader && mounted) {
        setState(() => _isLoadingDashboard = false);
      }
    }
  }

  Future<void> _restoreStateFromLocal() async {
    final stored = await _sessionStorage.loadPunchState(widget.session.userId);
    if (!mounted) return;

    if (stored == null) {
      setState(() {
        _isPunchedIn = false;
        _punchInTime = null;
      });
      return;
    }

    setState(() {
      _isPunchedIn = true;
      _punchInTime = stored.punchInTime;
      _todayStatus = 'Live';
    });
  }

  Future<void> _applyAttendanceState({
    required bool isPunchedIn,
    DateTime? punchInTime,
  }) async {
    if (!mounted) return;

    if (isPunchedIn) {
      final resolvedPunchInTime = punchInTime ?? DateTime.now();
      await _sessionStorage.savePunchIn(
        userId: widget.session.userId,
        punchInTime: resolvedPunchInTime,
      );

      if (!mounted) return;
      setState(() {
        _isPunchedIn = true;
        _punchInTime = resolvedPunchInTime;
        _todayStatus = 'Live';
      });
      return;
    }

    await _stopTracking();
    await _sessionStorage.clearPunchIn();

    if (!mounted) return;
    setState(() {
      _isPunchedIn = false;
      _punchInTime = null;
      _todayStatus = 'Out';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_handleLifecycleChange(state));
  }

  Future<void> _handleLifecycleChange(AppLifecycleState state) async {
    if (!_isPunchedIn) {
      if (state == AppLifecycleState.resumed) {
        await _loadStaffDashboard();
        if (await TrackingPermissions.hasForegroundLocation()) {
          await _refreshLocation(showLoader: false);
        }
      }
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        await _loadStaffDashboard();
        if (await TrackingPermissions.hasForegroundLocation()) {
          await _refreshLocation(showLoader: false);
        }
        if (!kIsWeb && _isPunchedIn) {
          _scheduleForegroundTracking();
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationService.dispose();
    _attendanceService.dispose();
    _sessionManager.dispose();
    super.dispose();
  }

  Future<LocationSnapshot> _withResolvedSpeed(LocationSnapshot snapshot) async {
    final last = await _sessionStorage.loadLastSync();
    final parsedKmh = double.tryParse(snapshot.speedKmh) ?? 0;
    final speedKmh = LocationService.resolveSpeedKmh(
      gpsSpeedMps: parsedKmh / 3.6,
      latitude: snapshot.latitude,
      longitude: snapshot.longitude,
      lastLatitude: last?.latitude,
      lastLongitude: last?.longitude,
      lastSyncTime: last?.syncTime,
    );
    return LocationSnapshot(
      latitude: snapshot.latitude,
      longitude: snapshot.longitude,
      speedKmh: speedKmh,
      batteryPercentage: snapshot.batteryPercentage,
    );
  }

  Future<void> _refreshDashboard() async {
    await _loadStaffDashboard();
    await _refreshLocation(showLoader: false);
  }

  Future<void> _startTracking() async {
    if (!_isPunchedIn || _foregroundTrackingActive) return;

    try {
      if (!await TrackingPermissions.hasForegroundLocation()) {
        debugPrint('[Tracking] Foreground location not granted — loop not started');
        return;
      }
      _startForegroundTrackingLoop();
    } catch (error, stackTrace) {
      debugPrint('[Tracking] _startTracking failed: $error');
      debugPrint('$stackTrace');
    }
  }

  void _startForegroundTrackingLoop() {
    if (_foregroundTrackingActive) return;
    _foregroundTrackingActive = true;
    _locationService.startPeriodicTracking(
      interval: TrackingConstants.trackLogInterval,
      onTick: _sendTrackLogFromForeground,
      onError: _onForegroundTrackingError,
    );
    debugPrint('[Tracking] Foreground loop started');
  }

  void _onForegroundTrackingError(Object error) {
    if (!mounted) return;
    debugPrint('[Tracking] Foreground tick failed: $error');
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
  }

  Future<void> _submitTrackLog(
    LocationSnapshot snapshot, {
    bool force = false,
  }) async {
    final resolved = await _withResolvedSpeed(snapshot);

    if (!force) {
      final distanceCheck = await _sessionStorage.evaluateTrackLogAt(
        resolved.latitude,
        resolved.longitude,
      );
      if (!distanceCheck.shouldSend) {
        if (mounted) {
          setState(() => _currentLocation = resolved);
        }
        return;
      }
    }

    if (!LocationService.hasValidCoordinates(
      resolved.latitude,
      resolved.longitude,
    )) {
      debugPrint('[Tracking] Skipping track_log — invalid GPS coordinates');
      return;
    }

    final batteryPercentage = await _locationService.readBatteryPercentage();
    final coords = LocationService.coordinatesForApi(
      resolved.latitude,
      resolved.longitude,
    );
    debugPrint(
      '[Tracking] track_log lat=${coords['latitude']} lng=${coords['longitude']} '
      'speed=${resolved.speedKmh}km/h battery=$batteryPercentage%',
    );
    final result = await _attendanceService.trackLogLocation(
      userId: widget.session.userId,
      latitude: coords['latitude']!,
      longitude: coords['longitude']!,
      speed: resolved.speedKmh,
      batteryPercentage: batteryPercentage,
    );
    await _recordTrackLog(
      resolved,
      result: result,
      batteryPercentage: batteryPercentage,
    );
  }

  Future<void> _recordTrackLog(
    LocationSnapshot snapshot, {
    required AttendanceResult result,
    String? batteryPercentage,
  }) async {
    if (!mounted) return;
    final syncTime = DateTime.now();
    final battery = batteryPercentage ?? snapshot.batteryPercentage;
    final enrichedSnapshot = LocationSnapshot(
      latitude: snapshot.latitude,
      longitude: snapshot.longitude,
      speedKmh: snapshot.speedKmh,
      batteryPercentage: battery,
    );
    setState(() {
      _currentLocation = enrichedSnapshot;
    });
    if (result.isSuccess) {
      await _sessionStorage.saveLastSync(
        latitude: enrichedSnapshot.latitude,
        longitude: enrichedSnapshot.longitude,
        speedKmh: enrichedSnapshot.speedKmh,
        batteryPercentage: battery,
        syncTime: syncTime,
      );
      _appendLiveRoutePoint(
        latitude: enrichedSnapshot.latitude,
        longitude: enrichedSnapshot.longitude,
        timestamp: syncTime,
        speed: enrichedSnapshot.speedKmh,
        batteryPercentage: battery,
      );
    }
    _addLog(
      action: 'Track Log',
      snapshot: enrichedSnapshot,
      message: result.message ?? 'Location synced',
      success: result.isSuccess,
    );
  }

  Future<void> _stopTracking() async {
    _locationService.stopPeriodicTracking();
    _foregroundTrackingActive = false;
  }

  Future<void> _sendTrackLogFromForeground(LocationSnapshot snapshot) async {
    if (!_isPunchedIn || _isSendingTrackLog) return;
    _isSendingTrackLog = true;

    try {
      await _submitTrackLog(snapshot);
    } catch (error) {
      debugPrint('[Tracking] track_log failed: $error');
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

  /// Adds API [trackPoints] without removing pins already loaded today.
  void _mergeApiRoutePoints(List<TrackPoint> incoming) {
    if (incoming.isEmpty) return;

    final merged = [..._dayRoutePoints];
    final seen = merged.map((point) => point.uniqueKey).toSet();
    var added = false;

    for (final point in incoming) {
      if (seen.add(point.uniqueKey)) {
        merged.add(point);
        added = true;
      }
    }

    if (!added) return;

    merged.sort(_sortTrackPoints);
    setState(() => _dayRoutePoints = merged);
  }

  int _sortTrackPoints(TrackPoint a, TrackPoint b) {
    if (a.timestamp == null && b.timestamp == null) return 0;
    if (a.timestamp == null) return 1;
    if (b.timestamp == null) return -1;
    return a.timestamp!.compareTo(b.timestamp!);
  }

  void _appendLiveRoutePoint({
    required double latitude,
    required double longitude,
    required DateTime timestamp,
    String? speed,
    String? batteryPercentage,
    int? attendanceId,
  }) {
    if (!LocationService.hasValidCoordinates(latitude, longitude)) return;

    final point = TrackPoint(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      speed: speed,
      batteryPercentage: batteryPercentage,
      attendanceId: attendanceId,
    );

    final alreadyShown = _dayRoutePoints.any(
          (item) => item.uniqueKey == point.uniqueKey,
        ) ||
        _liveRoutePoints.any((item) => item.uniqueKey == point.uniqueKey);
    if (alreadyShown) return;

    setState(() => _liveRoutePoints.add(point));
  }

  List<TrackPoint> _mapRoutePoints() {
    final merged = [..._dayRoutePoints];
    final seen = merged.map((point) => point.uniqueKey).toSet();

    for (final point in _liveRoutePoints) {
      if (seen.add(point.uniqueKey)) {
        merged.add(point);
      }
    }

    merged.sort(_sortTrackPoints);
    return merged;
  }

  LatLng? _currentMapLocation() {
    final location = _currentLocation;
    if (location == null) return null;
    if (!LocationService.hasValidCoordinates(
      location.latitude,
      location.longitude,
    )) {
      return null;
    }
    return LatLng(location.latitude, location.longitude);
  }

  Future<void> _refreshLocation({bool showLoader = true}) async {
    if (showLoader) setState(() => _isBusy = true);
    try {
      final last = await _sessionStorage.loadLastSync();
      final snapshot = await _locationService.getCurrentSnapshot(
        lastLatitude: last?.latitude,
        lastLongitude: last?.longitude,
        lastSyncTime: last?.syncTime,
      );
      if (!mounted) return;
      setState(() => _currentLocation = snapshot);
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
    if (_isLiveForUi()) {
      _showMessage('You are already ON DUTY. Use Punch Out to end your shift.');
      return;
    }
    setState(() => _isBusy = true);

    try {
      final permissions = await TrackingPermissions.ensureForBackgroundTracking();
      if (!permissions.granted) {
        throw LocationException(permissions.message);
      }

      // Optional — do not block punch in if user chose "While using the app".
      if (!kIsWeb) {
        unawaited(TrackingPermissions.requestBackgroundIfNeeded());
        unawaited(TrackingPermissions.requestNotificationIfNeeded());
      }

      final snapshot = await _locationService.getCurrentSnapshot();
      final coords = LocationService.coordinatesForApi(
        snapshot.latitude,
        snapshot.longitude,
      );
      final result = await _attendanceService.punchIn(
        userId: widget.session.userId,
        latitude: coords['latitude']!,
        longitude: coords['longitude']!,
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
        _todayStatus = 'Live';
        _currentLocation = snapshot;
      });

      _appendLiveRoutePoint(
        latitude: snapshot.latitude,
        longitude: snapshot.longitude,
        timestamp: punchInTime,
        speed: snapshot.speedKmh,
        batteryPercentage: snapshot.batteryPercentage,
      );

      _addLog(
        action: 'Punch In',
        snapshot: snapshot,
        message: result.message ?? 'Punched in successfully',
      );

      try {
        await _submitTrackLog(snapshot, force: true);
      } catch (error, stackTrace) {
        debugPrint('[PunchIn] Initial track_log failed: $error');
        debugPrint('$stackTrace');
      }

      try {
        await _startTracking();
      } catch (error, stackTrace) {
        debugPrint('[PunchIn] Tracking loop failed to start: $error');
        debugPrint('$stackTrace');
      }

      unawaited(_loadStaffDashboard());

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
    if (!_isLiveForUi()) {
      _showMessage('You are OFF DUTY. Use Punch In to start your shift.');
      return;
    }
    setState(() => _isBusy = true);

    try {
      await _stopTracking();
      final snapshot = await _locationService.getCurrentSnapshot();
      final coords = LocationService.coordinatesForApi(
        snapshot.latitude,
        snapshot.longitude,
      );
      final result = await _attendanceService.punchOut(
        userId: widget.session.userId,
        latitude: coords['latitude']!,
        longitude: coords['longitude']!,
      );

      if (!result.isSuccess) {
        throw AttendanceException(result.message ?? result.raw);
      }

      final punchOutTime = DateTime.now();
      await _sessionStorage.clearPunchIn();

      if (!mounted) return;
      setState(() {
        _isPunchedIn = false;
        _punchInTime = null;
        _todayStatus = 'Out';
        _currentLocation = snapshot;
      });

      _appendLiveRoutePoint(
        latitude: snapshot.latitude,
        longitude: snapshot.longitude,
        timestamp: punchOutTime,
        speed: snapshot.speedKmh,
        batteryPercentage: snapshot.batteryPercentage,
      );

      _addLog(
        action: 'Punch Out',
        snapshot: snapshot,
        message: result.message ?? 'Punched out successfully',
      );

      unawaited(_loadStaffDashboard());
      _showMessage(result.message ?? 'Punch out successful');
    } on AttendanceException catch (error) {
      if (_isPunchedIn) unawaited(_startTracking());
      _showMessage(error.message, isError: true);
    } on LocationException catch (error) {
      if (_isPunchedIn) unawaited(_startTracking());
      _showMessage(error.message, isError: true);
    } catch (error) {
      if (_isPunchedIn) unawaited(_startTracking());
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
    await _sessionManager.clearSession();
    await _sessionStorage.clearPunchIn();

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
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

  String _clockDisplay() {
    if (!_isPunchedIn || _punchInTime == null) return '00 : 00 : 00';
    final time = _punchInTime!;
    return '${DateFormat('hh').format(time)} : ${DateFormat('mm').format(time)} : ${DateFormat('a').format(time)}';
  }

  String? _punchInDateLabel() {
    if (!_isPunchedIn || _punchInTime == null) return null;
    return 'Punched in on ${DateFormat('dd MMM, yyyy • hh:mm a').format(_punchInTime!)}';
  }

  bool _isLiveForUi() {
    if (_todayStatus != null && _todayStatus!.trim().isNotEmpty) {
      return _todayStatus!.trim().toLowerCase() == 'live';
    }
    return _isPunchedIn;
  }

  int _successfulTrackCount() =>
      _activityLog.where((e) => e.action == 'Track Log' && e.success).length;

  int _failedTrackCount() => _activityLog.where((e) => !e.success).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffold,
      bottomNavigationBar: const _DashboardBottomNav(selectedIndex: 0),
      body: RefreshIndicator(
        color: AppColors.secondary,
        onRefresh: _refreshDashboard,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _AttendanceHeader(
                name: widget.session.displayName,
                role: 'Field Marketing',
                employeeId: widget.session.userId,
                onLogout: _logout,
                isBusy: _isBusy,
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: _WorkingTimeCard(
                  todayStatus: _todayStatus,
                  isLive: _isLiveForUi(),
                  isBusy: _isBusy || _isLoadingDashboard,
                  clockDisplay: _clockDisplay(),
                  punchInDateLabel: _punchInDateLabel(),
                  onPunchIn: _handlePunchIn,
                  onPunchOut: _handlePunchOut,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (_isBusy || _isLoadingDashboard)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: AppColors.secondary,
                        ),
                      ),
                    ),
                  _AttendanceStatsRow(
                    trackCount: _successfulTrackCount(),
                    onDuty: _isPunchedIn ? 1 : 0,
                    failedCount: _failedTrackCount(),
                  ),
                  const SizedBox(height: 22),
                  AttendanceRouteMap(
                    routePoints: _mapRoutePoints(),
                    currentLocation: _currentMapLocation(),
                    isLive: _isLiveForUi(),
                    height: 300,
                  ),
                  const SizedBox(height: 22),
                  _SectionTitle(
                    icon: Icons.history_rounded,
                    title: 'Tracking Activity Log',
                  ),
                  const SizedBox(height: 10),
                  if (_activityLog.isEmpty)
                    _EmptyActivityCard(isPunchedIn: _isPunchedIn)
                  else
                    ..._activityLog.map(
                      (entry) => _ActivityTile(
                        entry: entry,
                        dateTimeFormat: _dateTimeFormat,
                      ),
                    ),
                  const SizedBox(height: 16),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttendanceHeader extends StatelessWidget {
  const _AttendanceHeader({
    required this.name,
    required this.role,
    required this.employeeId,
    required this.onLogout,
    required this.isBusy,
  });

  final String name;
  final String role;
  final String employeeId;
  final VoidCallback onLogout;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel = DateFormat('dd MMM, yyyy').format(DateTime.now());

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 24),
      decoration: const BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Colors.white.withValues(alpha: 0.2),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        role,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.82),
                        ),
                      ),
                    ],
                  ),
                ),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      onPressed: isBusy ? null : onLogout,
                      icon: const Icon(Icons.logout_rounded, color: Colors.white),
                      tooltip: 'Logout',
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  "Today's Attendance",
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  dateLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.88),
                  ),
                ),
              ],
            ),
           
          ],
        ),
      ),
    );
  }
}

class _WorkingTimeCard extends StatelessWidget {
  const _WorkingTimeCard({
    required this.todayStatus,
    required this.isLive,
    required this.isBusy,
    required this.clockDisplay,
    required this.punchInDateLabel,
    required this.onPunchIn,
    required this.onPunchOut,
  });

  final String? todayStatus;
  final bool isLive;
  final bool isBusy;
  final String clockDisplay;
  final String? punchInDateLabel;
  final VoidCallback onPunchIn;
  final VoidCallback onPunchOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = clockDisplay.split(' : ');
    final statusLabel = todayStatus?.trim().isNotEmpty == true
        ? todayStatus!.trim()
        : (isLive ? 'Live' : 'Out');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Today's Status",
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isLive ? const Color(0xFF22C55E) : AppColors.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                statusLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(parts.length * 2 - 1, (index) {
              if (index.isOdd) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    ':',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }
              final part = parts[index ~/ 2];
              return Container(
                constraints: const BoxConstraints(minWidth: 62),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.scaffold,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(
                  part,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }),
          ),
          if (punchInDateLabel != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(
                  Icons.event_available_outlined,
                  size: 18,
                  color: AppColors.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    punchInDateLabel!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isBusy ? null : (isLive ? onPunchOut : onPunchIn),
              icon: Icon(isLive ? Icons.logout_rounded : Icons.login_rounded),
              label: Text(isLive ? 'Punch Out' : 'Punch In'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.secondary,
                disabledBackgroundColor: AppColors.secondary.withValues(alpha: 0.4),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceStatsRow extends StatelessWidget {
  const _AttendanceStatsRow({
    required this.trackCount,
    required this.onDuty,
    required this.failedCount,
  });

  final int trackCount;
  final int onDuty;
  final int failedCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Today\'s Tracking',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Text(
                DateFormat('MMM').format(DateTime.now()),
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _SummaryStatCard(
                value: '$trackCount',
                label: 'Synced',
                color: AppColors.success,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SummaryStatCard(
                value: '$onDuty',
                label: 'On Duty',
                color: AppColors.secondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SummaryStatCard(
                value: '$failedCount',
                label: 'Failed',
                color: AppColors.danger,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SummaryStatCard extends StatelessWidget {
  const _SummaryStatCard({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardBottomNav extends StatelessWidget {
  const _DashboardBottomNav({required this.selectedIndex});

  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.dashboard_rounded,
                label: 'Dashboard',
                selected: selectedIndex == 0,
              ),
              const _NavItem(icon: Icons.fingerprint_rounded, selected: false),
              const _NavItem(icon: Icons.map_rounded, selected: false),
              const _NavItem(icon: Icons.bar_chart_rounded, selected: false),
              const _NavItem(icon: Icons.menu_rounded, selected: false),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    this.label,
    required this.selected,
  });

  final IconData icon;
  final String? label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.secondary : AppColors.textMuted;

    if (selected && label != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.secondary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 6),
            Text(
              label!,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    return Icon(icon, color: color, size: 24);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
  });

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 22),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }
}

class _EmptyActivityCard extends StatelessWidget {
  const _EmptyActivityCard({required this.isPunchedIn});

  final bool isPunchedIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: AppColors.secondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isPunchedIn
                    ? 'Tracking every 30 sec while on duty. Activity will appear here.'
                    : 'Punch in to start field attendance and location tracking.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
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
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: entry.success
              ? colorScheme.primaryContainer
              : colorScheme.errorContainer,
          child: Icon(
            entry.success ? Icons.check_rounded : Icons.error_outline_rounded,
            color: entry.success
                ? colorScheme.onPrimaryContainer
                : colorScheme.onErrorContainer,
          ),
        ),
        title: Text(
          entry.action,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            dateTimeFormat.format(entry.time),
            if (LocationService.hasValidCoordinates(
              entry.latitude,
              entry.longitude,
            ))
              LocationService.formatCoordinatePair(
                entry.latitude,
                entry.longitude,
              ),
            if (entry.message != null) entry.message!,
          ].join('\n'),
        ),
        isThreeLine: true,
      ),
    );
  }
}
