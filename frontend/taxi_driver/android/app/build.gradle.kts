import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Credenciales de firma de release. El archivo keystore.properties y el .jks
// estan en .gitignore: no se suben al repo. Para compilar release en otra
// maquina hay que copiarlos a mano.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("app/keystore.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}
val tieneKeystore = keystorePropertiesFile.exists() && keystoreProperties.getProperty("storeFile") != null

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
        applicationId = "com.taxirapid.taxi_driver"
        // maplibre_gl exige API 21 como minimo. `flutter.minSdkVersion` baja de
        // ahi en versiones antiguas, asi que se fija a mano.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
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

            // El plugin de Flutter activa minify y el resource shrinker en
            // release. El shrinker de AGP elimina `res/raw/spacebell.mp3`
            // porque Dart lo referencia solo por nombre de cadena (no por
            // `R.raw`), pese al `res/values/keep.xml`. Se apagan para que el
            // sonido de la notificacion entre SIEMPRE al APK.
            isMinifyEnabled = false
            isShrinkResources = false
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
