import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.spheres.spheres_app"
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
        applicationId = "com.spheres.spheres_app"
        minSdk = flutter.minSdkVersion // Veilid requires API 21 (Android 5.0) minimum
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            // Never fall back to the debug keystore. Its signing key is public,
            // so a debug-signed "release" APK can be forged by anyone and can
            // never be upgraded to a properly signed build without an uninstall.
            // Without a keystore this stays null and the release is refused
            // below, rather than silently signed with a key everyone has.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                null
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
}

// Fail only when a release artifact is actually being produced. Checking here
// rather than inside buildTypes {} matters: that block is evaluated at
// configuration time for every invocation, so throwing there would also break
// debug builds.
gradle.taskGraph.whenReady {
    if (keystorePropertiesFile.exists()) return@whenReady

    val buildingRelease = allTasks.any { task ->
        task.name.contains("Release") &&
            listOf("assemble", "bundle", "package", "install").any { task.name.startsWith(it) }
    }

    if (buildingRelease) {
        throw GradleException(
            "Cannot build a release: android/key.properties is missing.\n" +
            "Create it with keyAlias, keyPassword, storeFile and storePassword, " +
            "or build a debug variant instead.\n" +
            "Releases must never be signed with the public Android debug key."
        )
    }
}

flutter {
    source = "../.."
}
