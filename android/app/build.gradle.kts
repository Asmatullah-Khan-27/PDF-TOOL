import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from android/key.properties when present. The file is
// git-ignored; see docs/STORE_SETUP.md for the exact steps to create an upload
// keystore. When missing, release builds fall back to debug signing so the
// project still builds for local testing (clearly reported below).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

// AdMob app id, injected at build time:
//   flutter build appbundle --dart-define=ADMOB_APP_ID=ca-app-pub-XXX~YYY
// Falls back to Google's official test app id.
val admobAppId: String = (project.findProperty("ADMOB_APP_ID") as String?)
    ?: System.getenv("ADMOB_APP_ID")
    ?: "ca-app-pub-3940256099942544~3347511713"

android {
    namespace = "com.pdffit.pdf_fit"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by several plugins (flutter_local_notifications style APIs and
        // newer Play Billing depend on java.time on older API levels).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.pdffit.pdf_fit"
        // 23 = Android 6.0. Required by the PDFium/Ads SDK combination and
        // gives reliable scoped-storage behaviour via the system picker.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["admobAppId"] = admobAppId

        // 64-bit ARM only. Every Play-certified device since 2019 is arm64, and
        // leaving out 32-bit/x86 keeps the APK small and buildable on low-disk
        // machines. Add "armeabi-v7a" here if you must support very old devices.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "PDF Fit: android/key.properties not found — release build is " +
                    "signed with the DEBUG key. This build cannot be uploaded to any store."
                )
                signingConfigs.getByName("debug")
            }
            // Code shrinking is intentionally disabled: it needs several GB of
            // memory and adds risk with FFI-based plugins. The APK is already
            // small because unused ABIs are excluded above.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    // ---------------------------------------------------------------------
    // Store flavours
    //   play   -> Google Play build (AdMob + Play Billing)
    //   amazon -> Amazon Appstore build (no AdMob; Amazon IAP via plugin)
    // ---------------------------------------------------------------------
    flavorDimensions += "store"
    productFlavors {
        create("play") {
            dimension = "store"
            // Label comes from AndroidManifest (android:label="PDF Fit").
            manifestPlaceholders["admobAppId"] = admobAppId
        }
        create("amazon") {
            dimension = "store"
            // Fire OS has no Google Play services, so AdMob is disabled in the
            // flavour manifest. Keep the placeholder present for Gradle.
            manifestPlaceholders["admobAppId"] = admobAppId
            versionNameSuffix = "-amazon"
        }
    }

    packaging {
        resources {
            excludes += setOf("META-INF/DEPENDENCIES", "META-INF/LICENSE*")
        }
        // abiFilters does not always strip native libraries that transitive
        // dependencies (libdartjni, libdatastore_shared_counter) publish for
        // other ABIs, so exclude them explicitly. Without this the arm64 APK
        // still advertises armeabi-v7a / x86_64 and carries their .so files.
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
