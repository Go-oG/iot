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
    // Plugins resolved from the pub cache can live on a different Windows drive
    // than the project. Redirecting their build dir across drives makes AGP fail
    // with "this and base files have different roots", so only subprojects on the
    // same drive as newBuildDir are redirected; the others keep their default
    // build dir next to their own sources.
    if (project.projectDir.toPath().root == newBuildDir.asFile.toPath().root) {
        val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
