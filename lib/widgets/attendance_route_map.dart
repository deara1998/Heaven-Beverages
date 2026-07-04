import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:heaven_beverages/models/track_point.dart';
import 'package:heaven_beverages/services/location_service.dart';
import 'package:heaven_beverages/theme/app_theme.dart';
import 'package:intl/intl.dart';

class AttendanceRouteMap extends StatefulWidget {
  const AttendanceRouteMap({
    super.key,
    required this.routePoints,
    this.currentLocation,
    this.isLive = false,
    this.height = 300,
  });

  final List<TrackPoint> routePoints;
  final LatLng? currentLocation;
  final bool isLive;
  final double height;

  @override
  State<AttendanceRouteMap> createState() => _AttendanceRouteMapState();
}

class _AttendanceRouteMapState extends State<AttendanceRouteMap> {
  GoogleMapController? _controller;
  var _mapReady = false;
  var _currentZoom = 14.0;

  static const _defaultCenter = LatLng(22.815516, 70.822557);
  static const _singlePointZoom = 14.0;
  static const _boundsPadding = 72.0;

  /// Google marker hues — kept distinct: green / blue / red / cyan.
  static const _hueFirst = BitmapDescriptor.hueGreen;
  static const _hueTrack = BitmapDescriptor.hueBlue;
  static const _hueLast = BitmapDescriptor.hueRed;
  static const _hueLive = BitmapDescriptor.hueCyan;

  static const _colorFirst = Color(0xFF34A853);
  static const _colorTrack = Color(0xFF4285F4);
  static const _colorLast = Color(0xFFEA4335);
  static const _colorLive = Color(0xFF00ACC1);

  /// Lets pinch/drag work even when the map is inside a scroll view.
  static final _mapGestureRecognizers =
      <Factory<OneSequenceGestureRecognizer>>{
    Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  @override
  void didUpdateWidget(covariant AttendanceRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_mapReady &&
        (oldWidget.routePoints != widget.routePoints ||
            oldWidget.currentLocation != widget.currentLocation)) {
      unawaited(_fitCameraToRoute());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  List<LatLng> _allMapPositions() {
    final positions = widget.routePoints
        .where(
          (point) => LocationService.hasValidCoordinates(
            point.latitude,
            point.longitude,
          ),
        )
        .map((point) => point.latLng)
        .toList();

    final current = widget.currentLocation;
    if (current != null &&
        LocationService.hasValidCoordinates(
          current.latitude,
          current.longitude,
        )) {
      positions.add(current);
    }

    return positions;
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};
    final validRoute = widget.routePoints
        .where(
          (point) => LocationService.hasValidCoordinates(
            point.latitude,
            point.longitude,
          ),
        )
        .toList();

    if (validRoute.length == 1) {
      final point = validRoute.first;
      markers.add(
        _routeMarker(
          id: 'track_${point.uniqueKey}_0',
          point: point,
          hue: _hueFirst,
          title: 'First point',
        ),
      );
    } else {
      for (var index = 0; index < validRoute.length; index++) {
        final point = validRoute[index];
        final isFirst = index == 0;
        final isLast = index == validRoute.length - 1;

        final double hue;
        final String title;
        if (isFirst) {
          hue = _hueFirst;
          title = 'First — start';
        } else if (isLast) {
          hue = _hueLast;
          title = 'Last — latest';
        } else {
          hue = _hueTrack;
          title = 'Track ${index + 1}';
        }

        markers.add(
          _routeMarker(
            id: 'track_${point.uniqueKey}_$index',
            point: point,
            hue: hue,
            title: title,
          ),
        );
      }
    }

    final current = widget.currentLocation;
    if (current != null &&
        LocationService.hasValidCoordinates(
          current.latitude,
          current.longitude,
        )) {
      final matchesLastTrack = validRoute.isNotEmpty &&
          LocationService.distanceMeters(
                validRoute.last.latitude,
                validRoute.last.longitude,
                current.latitude,
                current.longitude,
              ) <
              8;

      if (!matchesLastTrack || widget.isLive) {
        markers.add(
          Marker(
            markerId: const MarkerId('current_location'),
            position: current,
            icon: BitmapDescriptor.defaultMarkerWithHue(_hueLive),
            zIndexInt: 2,
            infoWindow: InfoWindow(
              title: widget.isLive ? 'You are here' : 'Current location',
              snippet: widget.isLive ? 'Live tracking' : null,
            ),
          ),
        );
      }
    }

    return markers;
  }

  Marker _routeMarker({
    required String id,
    required TrackPoint point,
    required double hue,
    required String title,
  }) {
    return Marker(
      markerId: MarkerId(id),
      position: point.latLng,
      icon: BitmapDescriptor.defaultMarkerWithHue(hue),
      infoWindow: InfoWindow(
        title: title,
        snippet: _trackPointSnippet(point),
      ),
    );
  }

  String _trackPointSnippet(TrackPoint point) {
    final parts = <String>[];

    if (point.timestamp != null) {
      parts.add(
        'Time: ${DateFormat('dd MMM, hh:mm a').format(point.timestamp!.toLocal())}',
      );
    }

    if (point.speed != null) {
      parts.add('Speed: ${point.speed} km/h');
    }

    if (point.batteryPercentage != null) {
      parts.add('Battery: ${point.batteryPercentage}%');
    }

    if (point.attendanceId != null) {
      parts.add('Attendance: ${point.attendanceId}');
    }

    parts.add(
      'Lat: ${LocationService.formatLatitude(point.latitude)}, '
      'Lng: ${LocationService.formatLongitude(point.longitude)}',
    );

    return parts.join(' • ');
  }

  Set<Polyline> _buildPolylines() {
    final coordinates = widget.routePoints
        .where(
          (point) => LocationService.hasValidCoordinates(
            point.latitude,
            point.longitude,
          ),
        )
        .map((point) => point.latLng)
        .toList();

    final current = widget.currentLocation;
    if (current != null &&
        LocationService.hasValidCoordinates(
          current.latitude,
          current.longitude,
        )) {
      if (coordinates.isEmpty ||
          LocationService.distanceMeters(
                coordinates.last.latitude,
                coordinates.last.longitude,
                current.latitude,
                current.longitude,
              ) >
              8) {
        coordinates.add(current);
      } else {
        coordinates[coordinates.length - 1] = current;
      }
    }

    if (coordinates.length < 2) return const {};

    return {
      Polyline(
        polylineId: const PolylineId('day_route'),
        points: coordinates,
        color: AppColors.secondary,
        width: 5,
        geodesic: true,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
    };
  }

  Future<void> _fitCameraToRoute() async {
    final controller = _controller;
    if (controller == null) return;

    final positions = _allMapPositions();

    if (positions.isEmpty) {
      _currentZoom = _singlePointZoom;
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(_defaultCenter, _singlePointZoom),
      );
      return;
    }

    if (positions.length == 1) {
      _currentZoom = _singlePointZoom;
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(positions.first, _singlePointZoom),
      );
      return;
    }

    var south = positions.first.latitude;
    var north = positions.first.latitude;
    var west = positions.first.longitude;
    var east = positions.first.longitude;

    for (final point in positions.skip(1)) {
      south = south < point.latitude ? south : point.latitude;
      north = north > point.latitude ? north : point.latitude;
      west = west < point.longitude ? west : point.longitude;
      east = east > point.longitude ? east : point.longitude;
    }

    // Keep enough area visible so roads and nearby places show clearly.
    const minSpan = 0.012;
    if ((north - south).abs() < minSpan) {
      final mid = (north + south) / 2;
      south = mid - minSpan / 2;
      north = mid + minSpan / 2;
    }
    if ((east - west).abs() < minSpan) {
      final mid = (east + west) / 2;
      west = mid - minSpan / 2;
      east = mid + minSpan / 2;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );

    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, _boundsPadding),
      );
      _currentZoom = 13;
    } catch (_) {
      _currentZoom = _singlePointZoom;
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(positions.last, _singlePointZoom),
      );
    }
  }

  Future<void> _zoomBy(double delta) async {
    final controller = _controller;
    if (controller == null) return;

    _currentZoom = (_currentZoom + delta).clamp(5.0, 20.0);
    await controller.animateCamera(CameraUpdate.zoomTo(_currentZoom));
  }

  LatLng _initialTarget() {
    if (widget.currentLocation != null) return widget.currentLocation!;
    if (widget.routePoints.isNotEmpty) return widget.routePoints.first.latLng;
    return _defaultCenter;
  }

  @override
  Widget build(BuildContext context) {
    final hasRoute = widget.routePoints.isNotEmpty;
    final hasCurrent = widget.currentLocation != null;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.secondary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.map_rounded,
                    color: AppColors.secondary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Today's Route",
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                      ),
                      Text(
                        hasRoute || hasCurrent
                            ? '${widget.routePoints.length} track point(s) • pinch or +/− to zoom'
                            : 'Route will appear after tracking starts',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.textMuted,
                            ),
                      ),
                    ],
                  ),
                ),
                if (widget.isLive)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Live',
                          style: TextStyle(
                            color: AppColors.success,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: widget.height,
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _initialTarget(),
                    zoom: _singlePointZoom,
                  ),
                  mapType: MapType.normal,
                  markers: _buildMarkers(),
                  polylines: _buildPolylines(),
                  gestureRecognizers: _mapGestureRecognizers,
                  myLocationButtonEnabled: false,
                  myLocationEnabled: false,
                  zoomControlsEnabled:
                      !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
                  zoomGesturesEnabled: true,
                  scrollGesturesEnabled: true,
                  tiltGesturesEnabled: true,
                  rotateGesturesEnabled: true,
                  mapToolbarEnabled: false,
                  compassEnabled: true,
                  liteModeEnabled: false,
                  buildingsEnabled: true,
                  trafficEnabled: false,
                  minMaxZoomPreference: const MinMaxZoomPreference(5, 20),
                  onMapCreated: (controller) {
                    _controller = controller;
                    _mapReady = true;
                    unawaited(_fitCameraToRoute());
                  },
                  onCameraMove: (position) {
                    _currentZoom = position.zoom;
                  },
                ),
                Positioned(
                  right: 10,
                  top: 10,
                  child: Column(
                    children: [
                      _MapControlButton(
                        icon: Icons.add_rounded,
                        tooltip: 'Zoom in',
                        onPressed: () => unawaited(_zoomBy(1)),
                      ),
                      const SizedBox(height: 8),
                      _MapControlButton(
                        icon: Icons.remove_rounded,
                        tooltip: 'Zoom out',
                        onPressed: () => unawaited(_zoomBy(-1)),
                      ),
                      const SizedBox(height: 8),
                      _MapControlButton(
                        icon: Icons.my_location_rounded,
                        tooltip: 'Fit route',
                        onPressed: () => unawaited(_fitCameraToRoute()),
                      ),
                    ],
                  ),
                ),
                if (!hasRoute && !hasCurrent)
                  Container(
                    color: Colors.white.withValues(alpha: 0.82),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.location_searching_rounded,
                          size: 36,
                          color: AppColors.textMuted.withValues(alpha: 0.8),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No route yet for today',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppColors.textMuted,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                const _MapLegendDot(color: _colorFirst, label: 'First'),
                const _MapLegendDot(color: _colorTrack, label: 'Track'),
                const _MapLegendDot(color: _colorLast, label: 'Last'),
                if (widget.isLive)
                  const _MapLegendDot(color: _colorLive, label: 'Live'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 22, color: AppColors.primary),
          ),
        ),
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
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
        ),
      ],
    );
  }
}
