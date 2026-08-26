import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

val keystorePropertiesFile = rootProject.file("keystore.properties")
val useKeystoreProperties = keystorePropertiesFile.canRead()
val keystoreProperties = Properties()
if (useKeystoreProperties) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.google.devtools.ksp)
    alias(libs.plugins.androidx.navigation.safeargs)
    id("kotlin-parcelize")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

// ---------------------------------------------------------------------------
// Self-hosted repository configuration.
//
// Values come from repo.properties (see repo.properties.example) and fall back
// to environment variables of the same name. On the repository host,
// `appstore-client-config` prints a ready-to-use repo.properties.
//
// There are deliberately no defaults for the repository URL or the public key:
// an app store that silently falls back to a placeholder repository is a
// security bug, so the build fails instead.
// ---------------------------------------------------------------------------

val repoPropertiesFile = rootProject.file("repo.properties")
val repoProperties = Properties().apply {
    if (repoPropertiesFile.canRead()) {
        FileInputStream(repoPropertiesFile).use { load(it) }
    }
}

fun repoSetting(name: String, default: String? = null): String {
    val value = (repoProperties.getProperty(name) ?: System.getenv(name))?.trim()
    if (!value.isNullOrEmpty()) {
        return value
    }
    if (default != null) {
        return default
    }
    throw GradleException(
        "$name is not set. Copy repo.properties.example to repo.properties and fill it in, " +
                "or export $name in the environment. On the repository host, " +
                "`appstore-client-config` prints the correct values."
    )
}

// BuildConfig is generated as Java, so escape exactly what a Java string
// literal needs. Note that '$' must NOT be escaped here.
fun asJavaStringLiteral(value: String) =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val repoBaseUrl = repoSetting("REPO_BASE_URL").trimEnd('/').also {
    // Every connection is cast to HttpsURLConnection, so a plaintext URL would
    // crash at runtime rather than merely fail to verify.
    if (!it.startsWith("https://")) {
        throw GradleException("REPO_BASE_URL must start with https:// (got: $it)")
    }
}

val repoPublicKey = repoSetting("REPO_PUBLIC_KEY").also {
    // signify public key blob: 2 byte algorithm, 8 byte key id, 32 byte Ed25519 key.
    val decoded = try {
        Base64.getDecoder().decode(it)
    } catch (e: IllegalArgumentException) {
        throw GradleException("REPO_PUBLIC_KEY is not valid base64")
    }
    if (decoded.size != 42) {
        throw GradleException("REPO_PUBLIC_KEY must decode to 42 bytes, got ${decoded.size}")
    }
    if (decoded[0] != 'E'.code.toByte() || decoded[1] != 'd'.code.toByte()) {
        throw GradleException("REPO_PUBLIC_KEY is not an Ed25519 signify key")
    }
}

val repoKeyVersion = repoSetting("REPO_KEY_VERSION", "0").also {
    // Interpolated into the metadata URL.
    if (!it.matches(Regex("[0-9]+"))) {
        throw GradleException("REPO_KEY_VERSION must be a decimal number (got: $it)")
    }
}

// Phase 1 access control: a static key sent as an HTTP header on every request
// to the repository. Empty disables it. docs/security.md explains what this
// does and does not protect against.
val repoAccessKeyHeader = repoSetting("REPO_ACCESS_KEY_HEADER", "X-AppStore-Key").also {
    if (!it.matches(Regex("[A-Za-z0-9!#\$%&'*+.^_`|~-]+"))) {
        throw GradleException("REPO_ACCESS_KEY_HEADER is not a valid HTTP header name (got: $it)")
    }
}

val repoAccessKey = repoSetting("REPO_ACCESS_KEY", "").also {
    // Reject anything that could smuggle a second header or break the request line.
    if (!it.matches(Regex("[\\x21-\\x7e]*"))) {
        throw GradleException("REPO_ACCESS_KEY must be printable ASCII with no spaces")
    }
}

android {
    if (useKeystoreProperties) {
        signingConfigs {
            create("release") {
                storeFile = rootProject.file(keystoreProperties["storeFile"]!!)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                enableV4Signing = true
            }
        }
    }

    compileSdk = 36
    buildToolsVersion = "36.1.0"

    // Left as upstream so that merging upstream changes stays clean. Only the
    // applicationId below identifies the installed package.
    namespace = "app.grapheneos.apps"

    defaultConfig {
        // Distinct from upstream's app.grapheneos.apps so this store installs
        // alongside GrapheneOS Apps instead of colliding with it. Changing this
        // also requires updating rom/privapp-permissions-myappstore.xml.
        applicationId = "app.myappstore"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = versionCode.toString()

        buildConfigField(String::class.java.name, "REPO_BASE_URL", asJavaStringLiteral(repoBaseUrl))
        buildConfigField(String::class.java.name, "REPO_PUBLIC_KEY", asJavaStringLiteral(repoPublicKey))
        buildConfigField(String::class.java.name, "REPO_KEY_VERSION", asJavaStringLiteral(repoKeyVersion))
        buildConfigField(String::class.java.name, "REPO_ACCESS_KEY_HEADER", asJavaStringLiteral(repoAccessKeyHeader))
        buildConfigField(String::class.java.name, "REPO_ACCESS_KEY", asJavaStringLiteral(repoAccessKey))
    }

    buildTypes {
        getByName("release") {
            isShrinkResources = true
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (useKeystoreProperties) {
                signingConfig = signingConfigs.getByName("release")
            }
        }

        getByName("debug") {
            applicationIdSuffix = ".debug"
        }
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    androidResources {
        localeFilters += listOf("en")
    }

    packaging {
        resources.excludes.addAll(listOf(
            "META-INF/versions/*/OSGI-INF/MANIFEST.MF",
            "org/bouncycastle/pqc/**.properties",
            "org/bouncycastle/x509/**.properties",
        ))
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.constraintlayout)
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.fragment.ktx)
    implementation(libs.androidx.navigation.fragment.ktx)
    implementation(libs.androidx.navigation.ui.ktx)
    implementation(libs.androidx.preference.ktx)
    implementation(libs.androidx.swiperefreshlayout)

    implementation(libs.androidx.lifecycle.viewmodel)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)

    implementation(libs.material)

    implementation(libs.bcprov.jdk18on)

    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlin.retry)
    implementation(libs.kotlin.retry.result)

    implementation(libs.glide.core)
    ksp(libs.glide.ksp)
}
