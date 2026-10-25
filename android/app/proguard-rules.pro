# PDFium bindings are reached through dart:ffi symbol lookup, never by name from
# Java, but keep the plugin classes that the engines instantiate reflectively.
-keep class io.flutter.plugins.** { *; }
-keep class com.google.android.gms.ads.** { *; }

# Flutter engine entry points.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }

# in_app_purchase / Play Billing.
-keep class com.android.billingclient.** { *; }

# Suppress warnings from optional dependencies pulled in by plugins.
-dontwarn com.google.android.gms.**
-dontwarn org.jetbrains.annotations.**
