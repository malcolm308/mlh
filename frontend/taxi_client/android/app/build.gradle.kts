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
    namespace = "com.taxirapid.taxi_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.taxirapid.taxi_client"
        minSdk = flutter.minSdkVersion
        // Play Store exige API 36 (Android 16) o superior para apps nuevas.
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

            // R8 ofusca y elimina codigo Java/Kotlin no usado. El shrinker de
            // recursos queda apagado para no borrar ficheros que Dart
            // referencia por nombre de cadena (sonidos, etc.).
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
