import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import com.android.build.api.variant.LibraryAndroidComponentsExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Flutter plugins (notably :jni) declare their own flutter.ndkVersion.
// Finalize the public AGP DSL after those declarations and before native variants
// are created, rather than editing plugin caches or installing a missing SDK.
val runnerNdk = providers.environmentVariable("HARBOR_ANDROID_NDK_VERSION").orNull
val runnerCmake = providers.environmentVariable("HARBOR_ANDROID_CMAKE_VERSION").orNull
subprojects {
    pluginManager.withPlugin("com.android.application") {
        extensions.configure<ApplicationAndroidComponentsExtension> {
            finalizeDsl { android ->
                runnerNdk?.let { android.ndkVersion = it }
                runnerCmake?.let { android.externalNativeBuild.cmake.version = it }
            }
        }
    }
    pluginManager.withPlugin("com.android.library") {
        extensions.configure<LibraryAndroidComponentsExtension> {
            finalizeDsl { android ->
                runnerNdk?.let { android.ndkVersion = it }
                runnerCmake?.let { android.externalNativeBuild.cmake.version = it }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
