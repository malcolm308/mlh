# Reglas de R8 para el AAB de Google Play (app cliente).
#
# Flutter ya ofusca el codigo Dart con --obfuscate. Estas reglas protegen las
# clases Java/Kotlin que se instancian por reflexion (plugins, MapLibre y el
# motor) para que R8 no las elimine ni renombre sus miembros.
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# Motor de Flutter y plugins registrados por nombre.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# MapLibre: estilos, capas y callbacks se resuelven por reflexion/JNI.
-keep class org.maplibre.** { *; }
-dontwarn org.maplibre.**

# flutter_secure_storage usa Tink para cifrar los tokens de sesion.
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# Plugins que resuelven clases de plataforma por reflexion.
-keep class io.flutter.plugin.common.** { *; }
-keep class dev.fluttercommunity.plus.** { *; }
-keep class com.llfbandit.** { *; }
-dontwarn com.llfbandit.**

# flutter_patcher reemplaza el cargador de Flutter por reflexion. El build de
# Play no lo inicializa (PLAY_STORE_BUILD), pero el APK de Render si lo usa.
-keep class com.flutter_patcher.** { *; }
-dontwarn com.flutter_patcher.**
-keep class com.google.gson.** { *; }
-dontwarn com.google.gson.**

# package_info_plus y share_plus leen metadatos del manifest.
-keep class com.baseflow.** { *; }
-dontwarn com.baseflow.**
