plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.aivy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        // Required by flutter_local_notifications for scheduled reminders.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.aivy"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // A checked-in throwaway key, used only for sideloaded QA APKs.
        //
        // CI used to sign releases with the local debug keystore, but that file is
        // generated fresh on every runner, so the APK's SHA-1 changed each build and
        // could never be registered in Firebase -- Google sign-in failed with
        // DEVELOPER_ERROR every time. A fixed key gives a stable fingerprint:
        //   SHA-1 CF:1C:F9:09:41:A5:C2:45:A9:4E:50:C8:AA:B2:FF:E9:52:44:A6:90
        // Register that once in Firebase Console -> Project settings -> Android app.
        //
        // Play Store releases must use a real, secret upload key instead.
        create("qa") {
            storeFile = file("aivy-qa.keystore")
            storePassword = "aivyqa123"
            keyAlias = "aivyqa"
            keyPassword = "aivyqa123"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("qa")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
