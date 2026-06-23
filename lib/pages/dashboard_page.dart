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
import 'package:heaven_beverages/services/session_manager.dart';
import 'package:heaven_beverages/services/session_storage.dart';
import 'package:heaven_beverages/services/tracking_constants.dart';
import 'package:heaven_beverages/services/tracking_permissions.dart';
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
  final _timeFormat = DateFormat('hh:mm a');
  final _dateTimeFormat = DateFormat('dd MMM yyyy, hh:mm a');

  GoogleMapController? _mapController;
  bool _isPunchedIn = false;
  bool _isBusy = false;
  bool _isTracking = false;
  DateTime? _punchInTime;
  LocationSnapshot? _currentLocation;
  final List<AttendanceLogEntry> _activityLog = [];
  StreamSubscription<Map<String, dynamic>?>? _syncSubscription;
  StreamSubscription<Map<String, dynamic>?>? _locationSubscription;
  bool _isSendingTrackLog = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _syncSubscription =
          BackgroundTrackingService.syncUpdates().listen(_handleBackgroundSync);
      _locationSubscription = BackgroundTrackingService.locationUpdates()
          .listen(_handleLocationUpdate);
    }
    _restoreState();
    _loadLastSyncFromStorage();
    _refreshLocation(showLoader: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isPunchedIn) {
      if (state == AppLifecycleState.resumed) {
        _loadLastSyncFromStorage();
      }
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        _loadLastSyncFromStorage();
        if (!kIsWeb) {
          unawaited(BackgroundTrackingService.wakeUp(widget.session.userId));
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (!kIsWeb) {
          unawaited(BackgroundTrackingService.wakeUp(widget.session.userId));
        }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncSubscription?.cancel();
    _locationSubscription?.cancel();
    _mapController?.dispose();
    _locationService.dispose();
    _attendanceService.dispose();
    _sessionManager.dispose();
    super.dispose();
  }

  Future<void> _loadLastSyncFromStorage() async {
    final stored = await _sessionStorage.loadLastSync();
    if (!mounted || stored == null) return;

    setState(() {
      _currentLocation = LocationSnapshot(
        latitude: stored.latitude,
        longitude: stored.longitude,
        speedKmh: stored.speedKmh,
        batteryPercentage: stored.batteryPercentage,
      );
    });
    await _updateMapView();
  }

  List<LatLng> _trackingRoutePoints() {
    final points = <LatLng>[];
    for (final entry in _activityLog.reversed) {
      if (!_isValidMapPoint(entry.latitude, entry.longitude)) continue;
      if (!_isLocationAction(entry.action)) continue;
      if (!entry.success && entry.action == 'Track Log Failed') continue;
      points.add(LatLng(entry.latitude, entry.longitude));
    }
    return _simplifyRoute(points);
  }

  List<LatLng> _simplifyRoute(List<LatLng> points) {
    if (points.length <= 2) return points;

    const minDelta = 0.00012;
    final simplified = <LatLng>[points.first];
    for (var i = 1; i < points.length; i++) {
      final last = simplified.last;
      final point = points[i];
      final isLast = i == points.length - 1;
      final moved = (point.latitude - last.latitude).abs() >= minDelta ||
          (point.longitude - last.longitude).abs() >= minDelta;
      if (moved || isLast) {
        simplified.add(point);
      }
    }
    return simplified;
  }

  bool _isValidMapPoint(double lat, double lng) {
    return lat != 0 || lng != 0;
  }

  bool _isLocationAction(String action) {
    return action == 'Track Log' ||
        action == 'Punch In' ||
        action == 'Punch Out';
  }

  Set<Marker> _buildMapMarkers() {
    final markers = <Marker>{};

    for (final entry in _activityLog) {
      if (!_isValidMapPoint(entry.latitude, entry.longitude)) continue;

      if (entry.action == 'Punch In') {
        markers.add(
          Marker(
            markerId: const MarkerId('punch_in'),
            position: LatLng(entry.latitude, entry.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
            infoWindow: const InfoWindow(title: 'Punch In'),
            zIndexInt: 2,
          ),
        );
      } else if (entry.action == 'Punch Out') {
        markers.add(
          Marker(
            markerId: const MarkerId('punch_out'),
            position: LatLng(entry.latitude, entry.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
            infoWindow: const InfoWindow(title: 'Punch Out'),
            zIndexInt: 2,
          ),
        );
      }
    }

    return markers;
  }

  Set<Polyline> _buildMapPolylines() {
    final route = _trackingRoutePoints();
    if (route.length < 2) return {};

    return {
      Polyline(
        polylineId: const PolylineId('tracking_route'),
        points: route,
        color: const Color(0xFF2E7D32),
        width: 4,
        geodesic: true,
      ),
    };
  }

  Future<void> _focusMapOn(double latitude, double longitude) async {
    final controller = _mapController;
    if (controller == null) return;
    await controller.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(latitude, longitude), 17),
    );
  }

  Future<void> _updateMapView() async {
    final controller = _mapController;
    if (controller == null || kIsWeb) return;

    final points = <LatLng>[];
    final current = _currentLocation;
    if (current != null && _isValidMapPoint(current.latitude, current.longitude)) {
      points.add(LatLng(current.latitude, current.longitude));
    }
    points.addAll(_trackingRoutePoints());

    if (points.isEmpty) return;

    if (points.length == 1) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(points.first, 16),
      );
      return;
    }

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final point in points) {
      minLat = minLat < point.latitude ? minLat : point.latitude;
      maxLat = maxLat > point.latitude ? maxLat : point.latitude;
      minLng = minLng < point.longitude ? minLng : point.longitude;
      maxLng = maxLng > point.longitude ? maxLng : point.longitude;
    }

    if ((maxLat - minLat).abs() < 0.002) {
      minLat -= 0.001;
      maxLat += 0.001;
    }
    if ((maxLng - minLng).abs() < 0.002) {
      minLng -= 0.001;
      maxLng += 0.001;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
    await controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 72));
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

  void _handleLocationUpdate(Map<String, dynamic>? event) {
    if (!mounted || event == null) return;

    final latitude = event['latitude'];
    final longitude = event['longitude'];
    if (latitude is! num || longitude is! num) return;

    setState(() {
      _currentLocation = LocationSnapshot(
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
        speedKmh: event['speedKmh']?.toString() ?? '0',
        batteryPercentage: event['batteryPercentage']?.toString() ?? '0',
      );
    });
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
      setState(() {
        _currentLocation = snapshot;
      });
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
      _startForegroundTrackingLoop();
      return;
    }
    await _ensurePersistentTracking(requirePermissions: true);
  }

  Future<void> _ensurePersistentTracking({
    bool requirePermissions = false,
  }) async {
    if (kIsWeb || !_isPunchedIn) return;

    if (requirePermissions) {
      final permissions = await TrackingPermissions.ensureForBackgroundTracking();
      if (!permissions.granted) {
        _showMessage(permissions.message, isError: true);
        return;
      }
    } else if (!await TrackingPermissions.hasBackgroundTrackingPermissions()) {
      debugPrint('[Tracking] Permissions missing — open app to fix');
      return;
    }

    final started = await BackgroundTrackingService.ensureRunning(
      widget.session.userId,
    );
    if (!started && requirePermissions) {
      _showMessage(
        'Could not start field tracking. Please restart the app.',
        isError: true,
      );
    }
  }

  void _startForegroundTrackingLoop() {
    _locationService.startPeriodicTracking(
      interval: TrackingConstants.trackLogInterval,
      onTick: _sendTrackLogFromForeground,
      onError: _onForegroundTrackingError,
    );
    debugPrint('[Tracking] Web foreground loop started');
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

    final batteryPercentage = await _locationService.readBatteryPercentage();
    debugPrint(
      '[Tracking] track_log lat=${resolved.latitude} lng=${resolved.longitude} '
      'speed=${resolved.speedKmh}km/h battery=$batteryPercentage%',
    );
    final result = await _attendanceService.trackLogLocation(
      userId: widget.session.userId,
      latitude: resolved.latitude.toString(),
      longitude: resolved.longitude.toString(),
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
    if (!kIsWeb) {
      await BackgroundTrackingService.stop();
    }
  }

  Future<void> _sendTrackLogFromForeground(LocationSnapshot snapshot) async {
    if (!_isPunchedIn || _isSendingTrackLog || !kIsWeb) return;
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
      await _updateMapView();
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
      final permissions = await TrackingPermissions.ensureForBackgroundTracking();
      if (!permissions.granted) {
        throw LocationException(permissions.message);
      }

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

      await _submitTrackLog(snapshot, force: true);

      if (!kIsWeb) {
        unawaited(BackgroundTrackingService.requestBatteryExemption());
      }
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
    unawaited(_updateMapView());
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
    final location = _currentLocation;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: RefreshIndicator(
        onRefresh: () => _refreshLocation(showLoader: false),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _DashboardHeader(
                onLogout: _logout,
                isBusy: _isBusy,
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _EmployeeProfileCard(
                    name: widget.session.displayName,
                    mobileNo: widget.session.mobileNo,
                    employeeId: widget.session.userId,
                    isPunchedIn: _isPunchedIn,
                    punchInTime: _punchInTime,
                    isTracking: _isTracking,
                    timeFormat: _timeFormat,
                  ),
                  const SizedBox(height: 16),
                  _PunchActionCard(
                    isBusy: _isBusy,
                    isPunchedIn: _isPunchedIn,
                    onPunchIn: _handlePunchIn,
                    onPunchOut: _handlePunchOut,
                  ),
                  if (_isBusy) ...[
                    const SizedBox(height: 16),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  const SizedBox(height: 20),
                  _MapCard(
                    latitude: location?.latitude,
                    longitude: location?.longitude,
                    isTracking: _isTracking,
                    markers: _buildMapMarkers(),
                    polylines: _buildMapPolylines(),
                    onMapCreated: (controller) {
                      _mapController = controller;
                      unawaited(_updateMapView());
                    },
                  ),
                  const SizedBox(height: 14),
                  _LocationStatsGrid(
                    latitude: location?.latitude,
                    longitude: location?.longitude,
                    speedKmh: location?.speedKmh,
                    batteryPercentage: location?.batteryPercentage,
                    onRefresh: _isBusy ? null : () => _refreshLocation(),
                  ),
                  const SizedBox(height: 24),
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
                        onTap: _isValidMapPoint(entry.latitude, entry.longitude)
                            ? () => _focusMapOn(entry.latitude, entry.longitude)
                            : null,
                      ),
                    ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.onLogout,
    required this.isBusy,
  });

  final VoidCallback onLogout;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateFormat('EEEE, dd MMM yyyy').format(DateTime.now());

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 28),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B5E20), Color(0xFF2E7D32), Color(0xFF43A047)],
        ),
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
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.local_drink_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Heaven Beverages',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Field Attendance',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.88),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: isBusy ? null : onLogout,
                  icon: const Icon(Icons.logout_rounded, color: Colors.white),
                  tooltip: 'Logout',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              today,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmployeeProfileCard extends StatelessWidget {
  const _EmployeeProfileCard({
    required this.name,
    required this.mobileNo,
    required this.employeeId,
    required this.isPunchedIn,
    required this.punchInTime,
    required this.isTracking,
    required this.timeFormat,
  });

  final String name;
  final String mobileNo;
  final String employeeId;
  final bool isPunchedIn;
  final DateTime? punchInTime;
  final bool isTracking;
  final DateFormat timeFormat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = isPunchedIn ? const Color(0xFF2E7D32) : Colors.grey.shade600;

    return Card(
      elevation: 3,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 34,
                  backgroundColor: const Color(0xFF2E7D32),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
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
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.phone_android,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(mobileNo, style: theme.textTheme.bodyMedium),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'ID: $employeeId',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
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
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            if (isPunchedIn && punchInTime != null) ...[
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.schedule, size: 18, color: Colors.green.shade700),
                  const SizedBox(width: 8),
                  Text('Punched in at ${timeFormat.format(punchInTime!)}'),
                  const Spacer(),
                  if (isTracking)
                    Icon(Icons.gps_fixed, size: 18, color: Colors.green.shade700),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PunchActionCard extends StatelessWidget {
  const _PunchActionCard({
    required this.isBusy,
    required this.isPunchedIn,
    required this.onPunchIn,
    required this.onPunchOut,
  });

  final bool isBusy;
  final bool isPunchedIn;
  final VoidCallback onPunchIn;
  final VoidCallback onPunchOut;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: isBusy || isPunchedIn ? null : onPunchIn,
                icon: const Icon(Icons.login_rounded),
                label: const Text('Punch In'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  disabledBackgroundColor: Colors.green.shade200,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: isBusy || !isPunchedIn ? null : onPunchOut,
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Punch Out'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE65100),
                  disabledBackgroundColor: Colors.orange.shade200,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
        Icon(icon, color: const Color(0xFF2E7D32), size: 22),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: theme.colorScheme.primary,
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

class _LocationStatsGrid extends StatelessWidget {
  const _LocationStatsGrid({
    required this.latitude,
    required this.longitude,
    required this.speedKmh,
    required this.batteryPercentage,
    required this.onRefresh,
  });

  final double? latitude;
  final double? longitude;
  final String? speedKmh;
  final String? batteryPercentage;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatChip(
                icon: Icons.speed,
                label: 'Speed',
                value: speedKmh == null ? '--' : '$speedKmh km/h',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatChip(
                icon: Icons.battery_std_outlined,
                label: 'Battery',
                value: batteryPercentage == null ? '--' : '$batteryPercentage%',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatChip(
                icon: Icons.my_location,
                label: 'Latitude',
                value: latitude?.toStringAsFixed(5) ?? '--',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatChip(
                icon: Icons.explore_outlined,
                label: 'Longitude',
                value: longitude?.toStringAsFixed(5) ?? '--',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Refresh GPS'),
          ),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF2E7D32)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.latitude,
    required this.longitude,
    required this.isTracking,
    required this.markers,
    required this.polylines,
    required this.onMapCreated,
  });

  final double? latitude;
  final double? longitude;
  final bool isTracking;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final ValueChanged<GoogleMapController> onMapCreated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLocation = latitude != null && longitude != null;
    final latLng = hasLocation ? LatLng(latitude!, longitude!) : null;

    return Card(
      elevation: 2,
      shadowColor: Colors.black12,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.map_outlined, color: theme.colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Live Map',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (isTracking)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Text(
                          'LIVE',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.green.shade800,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: const [
                    _MapLegendDot(color: Colors.blue, label: 'You'),
                    _MapLegendDot(color: Color(0xFF2E7D32), label: 'Route'),
                    _MapLegendDot(color: Colors.green, label: 'In'),
                    _MapLegendDot(color: Colors.orange, label: 'Out'),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(
            height: 280,
            child: hasLocation && !kIsWeb
                ? GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: latLng!,
                      zoom: 16,
                    ),
                    markers: markers,
                    polylines: polylines,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                    padding: const EdgeInsets.only(top: 8, right: 48, bottom: 24),
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

class _MapLegendDot extends StatelessWidget {
  const _MapLegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 11),
        ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.entry,
    required this.dateTimeFormat,
    this.onTap,
  });

  final AttendanceLogEntry entry;
  final DateFormat dateTimeFormat;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        onTap: onTap,
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
        trailing: onTap == null
            ? null
            : Icon(Icons.map_outlined, color: colorScheme.primary, size: 20),
        title: Text(
          entry.action,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
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
