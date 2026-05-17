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
// Fallback `namespace` for plugins published before AGP 8 made it mandatory
// (e.g. flutter_dynamic_icon 2.1.0). Without this, configuration fails with:
//   "Namespace not specified. Specify a namespace in the module's build file"
// AGP no longer reads the legacy `package` attribute in the plugin's
// AndroidManifest.xml as a namespace fallback, so we do it ourselves at the
// root Gradle level. This block MUST sit BEFORE the `evaluationDependsOn`
// block below — that one forces subprojects to evaluate, after which we
// can no longer register `afterEvaluate` hooks on them.
subprojects {
    plugins.withId("com.android.library") {
        configureLegacyNamespace()
    }
    plugins.withId("com.android.application") {
        configureLegacyNamespace()
    }
}

fun Project.configureLegacyNamespace() {
    val androidExt = extensions.findByName("android") ?: return
    val getNs = androidExt.javaClass.getMethod("getNamespace")
    val ns = getNs.invoke(androidExt) as String?
    if (!ns.isNullOrEmpty()) return
    val manifestFile = file("src/main/AndroidManifest.xml")
    if (!manifestFile.exists()) return
    val pkg = Regex("""package="([^"]+)"""")
        .find(manifestFile.readText())
        ?.groupValues
        ?.get(1) ?: return
    val setNs = androidExt.javaClass.getMethod(
        "setNamespace",
        String::class.java,
    )
    setNs.invoke(androidExt, pkg)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
