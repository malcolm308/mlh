import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Credenciales de firma de release. Se aceptan dos nombres porque el proyecto
// ya venia usando `app/keystore.properties` y la documentacion de Flutter/Play
// habla de `key.properties`; cualquiera de los dos funciona. Ambos y el .jks
// estan en .gitignore: no se suben al repo.
val keystoreProperties = Properties()
val archivoFirma = listOf(
    rootProject.file("key.properties"),
    rootProject.file("app/key.properties"),
    rootProject.file("app/keystore.properties"),
).firstOrNull { it.exists() }
if (archivoFirma != null) {
    keystoreProperties.load(archivoFirma.inputStream())
}
val tieneKeystore = archivoFirma != null && keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.taxirapid.taxi_driver"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // `flutter_local_notifications` llama a APIs de java.time que no
        // existen en el runtime de Android por debajo de la 26. Sin esto el
        // build falla al desempacarlo, no al compilar.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // El paquete antiguo (com.taxirapid.taxi_driver) quedo atado en el
        // registro de Android a una clave cuya contrasena se perdio, y una
        // cuenta de distribucion limitada no puede reclamar nombres usados.
        // Se publica como app nueva en Play con este identificador.
        // El `namespace` sigue igual: solo cambia el id de la app, no el
        // codigo Kotlin ni los recursos.
        applicationId = "com.taxirapid.driver"
        // maplibre_gl exige API 21 como minimo. `flutter.minSdkVersion` baja de
        // ahi en versiones antiguas, asi que se fija a mano.
        minSdk = flutter.minSdkVersion
        // Play Store exige API 36 (Android 16) o superior para apps nuevas.
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // El plugin de notificaciones y el de badge tambien traen multiples
        // dex; con minSdk 21 se puede, pero hay que decirlo.
        multiDexEnabled = true
    }

    signingConfigs {
        if (tieneKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Sin keystore.release definido se firma con debug, que es lo que
            // permite seguir con `flutter run --release` en desarrollo.
            signingConfig = if (tieneKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 ofusca y elimina codigo no usado. El resource shrinker sigue
            // apagado: elimina `res/raw/spacebell.mp3` porque Dart lo
            // referencia solo por su nombre de cadena, pese al keep.xml (ver
            // tambien `android.enableResourceOptimizations=false`). El sonido
            // de la notificacion tiene que entrar SIEMPRE.
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Biblioteca de java.time que el desugaring necesita para ofrecer en
    // Android antiguo las APIs que el plugin de notificaciones usa.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
