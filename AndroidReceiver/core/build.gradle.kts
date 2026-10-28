plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)
    // Public API: control messages reach the app as JsonObject.
    api(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    // Test-only: self-signed P-256 certificates for the loopback TLS tests.
    // On Android the Keystore issues the receiver's certificate itself.
    testImplementation(libs.bouncycastle.pkix)
}

tasks.test {
    // The Swift implementation's checked-in vectors (fixtures/receiver-protocol).
    val fixtures = rootProject.layout.projectDirectory.dir("../fixtures/receiver-protocol")
    inputs.dir(fixtures)
    systemProperty("meow.fixtures", fixtures.asFile.absolutePath)
}
