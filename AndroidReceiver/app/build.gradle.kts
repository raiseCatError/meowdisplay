plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// Release builds take their version and upload key from CI
// (.github/workflows/release-android.yml); nothing secret lives in the repo.
val uploadStoreFile: String? = System.getenv("MEOW_UPLOAD_STORE_FILE")

android {
    namespace = "com.raisecaterror.meowdisplay.android"
    // Current AndroidX needs API 37 to compile against; the app still targets 36.
    compileSdk {
        version = release(37) { minorApiLevel = 2 }
    }

    defaultConfig {
        // Confirm against the Play Console listing before the first upload.
        applicationId = "com.raisecaterror.meowdisplay.android"
        minSdk = 29
        // 36 meets Play's current requirement. 37 opts in to Android 17's
        // local-network permission, which this LAN-only app must handle first.
        targetSdk = 36
        versionCode = providers.gradleProperty("meow.versionCode").map(String::toInt).getOrElse(1)
        versionName = providers.gradleProperty("meow.versionName").getOrElse("2.0.0-dev")
    }

    signingConfigs {
        if (uploadStoreFile != null) {
            create("upload") {
                fun required(name: String) = requireNotNull(System.getenv(name)) { "$name is required with MEOW_UPLOAD_STORE_FILE" }
                storeFile = file(uploadStoreFile)
                storePassword = required("MEOW_UPLOAD_STORE_PASSWORD")
                keyAlias = required("MEOW_UPLOAD_KEY_ALIAS")
                keyPassword = required("MEOW_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Unsigned unless CI provides the upload key.
            signingConfig = signingConfigs.findByName("upload")
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    // Fold and hinge bounds for the adaptive controls (foldables, dual screens).
    implementation(libs.androidx.window)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
}
