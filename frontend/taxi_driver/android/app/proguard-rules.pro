# Reglas de R8 para el AAB de Google Play.
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

# Servicio en primer plano de las ofertas.
-keep class id.flutter.flutter_background_service.** { *; }

# Notificaciones: serializa la programacion con Gson.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.google.gson.** { *; }
-dontwarn com.google.gson.**

# flutter_secure_storage usa Tink para cifrar los tokens.
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# flutter_patcher reemplaza el cargador de Flutter por reflexion. El build de
# Play no lo inicializa (PLAY_STORE_BUILD), pero el APK de Render si lo usa.
-keep class com.flutter_patcher.** { *; }
-dontwarn com.flutter_patcher.**
-keep class com.google.gson.** { *; }
-dontwarn com.google.gson.**
