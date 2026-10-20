plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val distributionStore = providers.environmentVariable("HARBOR_ANDROID_KEYSTORE").orNull
val distributionAlias = providers.environmentVariable("HARBOR_ANDROID_KEY_ALIAS").orNull
val distributionStorePassword = providers.environmentVariable("HARBOR_ANDROID_STORE_PASSWORD").orNull
val distributionKeyPassword = providers.environmentVariable("HARBOR_ANDROID_KEY_PASSWORD").orNull
val requireStableSigning = providers.environmentVariable("HARBOR_ANDROID_REQUIRE_STABLE_SIGNING")
    .orNull == "true"
val hasDistributionSigning = listOf(distributionStore, distributionAlias,
    distributionStorePassword, distributionKeyPassword).any { !it.isNullOrBlank() }
if (requireStableSigning || hasDistributionSigning) {
    require(listOf(distributionStore, distributionAlias, distributionStorePassword,
        distributionKeyPassword).all { !it.isNullOrBlank() }) {
        "Persistent Android signing requires a keystore, alias and both passwords."
    }
    require(file(distributionStore!!).isFile) { "Android signing keystore is unavailable." }
}

android {
    namespace = "dev.harbor.harbor_mail"
    compileSdk = flutter.compileSdkVersion
    // CI may select a verified preinstalled NDK; local builds keep Flutter's default.
    ndkVersion = providers.environmentVariable("HARBOR_ANDROID_NDK_VERSION")
        .orElse(flutter.ndkVersion).get()
    buildToolsVersion = "36.0.0"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // apksig uses java.time; desugar it for supported Android versions below API 26.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.harbor.harbor_mail"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasDistributionSigning) {
            create("distribution") {
                storeFile = file(distributionStore!!)
                storePassword = distributionStorePassword
                keyAlias = distributionAlias
                keyPassword = distributionKeyPassword
                storeType = providers.environmentVariable("HARBOR_ANDROID_STORE_TYPE")
                    .orElse("PKCS12").get()
            }
        }
    }

    buildTypes {
        debug {
            // Development APKs coexist with a separately signed release app.
            applicationIdSuffix = ".dev"
            if (hasDistributionSigning) {
                signingConfig = signingConfigs.getByName("distribution")
            }
        }
        release {
            // An absent distribution key produces an unsigned release, never a debug-signed one.
            signingConfig = if (hasDistributionSigning) signingConfigs.getByName("distribution") else null
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
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.core:core:1.17.0")
    implementation("com.android.tools.build:apksig:9.1.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
