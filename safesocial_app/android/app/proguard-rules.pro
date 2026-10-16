# The AutoEar engine is reached by name from nowhere, but its serializers
# are looked up by kotlinx.serialization at run time; keep both whole.
-keep class org.autoear.** { *; }
-keepclassmembers class org.autoear.** { *** Companion; }
-keepclasseswithmembers class org.autoear.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class org.autoear.**$$serializer { *; }
-dontwarn kotlinx.serialization.**
