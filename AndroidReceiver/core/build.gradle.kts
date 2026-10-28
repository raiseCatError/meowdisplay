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
    // The Swift workspace engine's vectors (fixtures/workspace, MacTests/WindowWorkspaceVectorTests).
    val workspaceFixtures = rootProject.layout.projectDirectory.dir("../fixtures/workspace")
    inputs.dir(workspaceFixtures)
    systemProperty("meow.workspaceFixtures", workspaceFixtures.asFile.absolutePath)
    // Natural Touch gesture vectors shared with the Swift engine (fixtures/gestures).
    val gestureFixtures = rootProject.layout.projectDirectory.dir("../fixtures/gestures")
    inputs.dir(gestureFixtures)
    systemProperty("meow.gestureFixtures", gestureFixtures.asFile.absolutePath)
    // Stage Peek machine and layout vectors shared with the Swift engine (fixtures/stage-peek).
    val stagePeekFixtures = rootProject.layout.projectDirectory.dir("../fixtures/stage-peek")
    inputs.dir(stagePeekFixtures)
    systemProperty("meow.stagePeekFixtures", stagePeekFixtures.asFile.absolutePath)
    // Zoom While Typing caret-follow vectors shared with the Swift calculator (fixtures/viewport).
    val viewportFixtures = rootProject.layout.projectDirectory.dir("../fixtures/viewport")
    inputs.dir(viewportFixtures)
    systemProperty("meow.viewportFixtures", viewportFixtures.asFile.absolutePath)
    // Remote Access endpoint and knock-frame vectors shared with the Swift code (fixtures/remote).
    val remoteFixtures = rootProject.layout.projectDirectory.dir("../fixtures/remote")
    inputs.dir(remoteFixtures)
    systemProperty("meow.remoteFixtures", remoteFixtures.asFile.absolutePath)
}
