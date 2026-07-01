# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Background service (release / R8)
-keep class id.flutter.flutter_background_service.** { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep *;
}

# Geolocator
-keep class com.baseflow.geolocator.** { *; }

# Local notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# Gson / JSON (if used by plugins)
-keepattributes Signature
-keepattributes *Annotation*
