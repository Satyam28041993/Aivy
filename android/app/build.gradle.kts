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
        // A checked-in debug keystore, so every build — local or CI — signs with
        // the same certificate.
        //
        // Gradle's own debug keystore is generated on first use, which means a
        // fresh GitHub runner makes a new one on every run and the APK's SHA-1
        // changes each time. Google sign-in matches the app by that SHA-1, so it
        // could never be registered in Firebase: sign-in failed with
        // DEVELOPER_ERROR on every build, and re-registering would have lasted
        // exactly one build.
        //
        // This is a debug credential, deliberately (password "android", the
        // standard alias) — it carries no more trust than the random one it
        // replaces. Publishing to Play would need a real release keystore held
        // in secrets instead.
        create("aivy") {
            storeFile = file("aivy-debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("aivy")
        }
        debug {
            signingConfig = signingConfigs.getByName("aivy")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
