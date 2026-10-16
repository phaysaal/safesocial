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
        // flutter_local_notifications needs java.time on older Android.
        isCoreLibraryDesugaringEnabled = true
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

    // Two builds of the same app. `foss` (F-Droid, sideload, CI) carries no
    // Google code of any kind and wakes through a UnifiedPush distributor the
    // person installs, such as ntfy. `play` (Google Play) also embeds the
    // UnifiedPush FCM distributor, which registers with Google Play services
    // the way a browser does (the relay's VAPID key as the sender; no Firebase
    // project, no Google SDK, no proprietary code) so that phone wakes with
    // nothing else installed and no persistent notification. The Dart code
    // is identical; `appFlavor` tells it which build it is in.
    flavorDimensions += "store"
    productFlavors {
        create("foss") { dimension = "store" }
        create("play") { dimension = "store" }
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
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // The Play build's built-in distributor; see productFlavors above. It
    // declares its own receivers in its manifest, so nothing is added to ours.
    "playImplementation"("org.unifiedpush.android:embedded-fcm-distributor:3.1.0")
    // The AutoEar v2 note engine: a pure-JVM jar (no Android, no network)
    // that turns English transcript text into notes. Built from the AutoEar
    // repository (v2/engine) and copied here; see docs/call_notes.md.
    implementation(files("libs/autoear-engine.jar"))
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
    testImplementation("junit:junit:4.13.2")
}

// Two plugins pull in Google Tink under two artifact names — `tink` (via the
// UnifiedPush connector) and `tink-android` (via androidx.security, used by
// flutter_secure_storage). They ship the same classes, which fails the build
// with "Duplicate class". tink-android is the superset for Android; keep it.
configurations.all {
    exclude(group = "com.google.crypto.tink", module = "tink")
}
