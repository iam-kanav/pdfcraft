# Optional codecs/recognizers referenced by libraries but not bundled.
-dontwarn com.gemalto.jp2.**
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# PdfBox-Android loads fonts, filters and resources reflectively.
-keep class com.tom_roush.** { *; }
-dontwarn com.tom_roush.**

# ML Kit discovers its components reflectively via no-arg constructors.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
