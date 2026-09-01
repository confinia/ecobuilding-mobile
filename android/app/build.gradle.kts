import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Clé d'ENVOI Play (android/key.properties, jamais versionné — voir
// .gitignore). Sans le fichier, la signature debug demeure : le poste d'un
// contributeur compile sans détenir la clé du magasin.
val cleEnvoi = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "io.confinia.ecobuilding"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.confinia.ecobuilding"
        // Android 8 : même intention que la cible iOS 16 côté iPhone — couvrir
        // les appareils anciens, nos utilisateurs visitant des logements et non
        // des salons de la tech.
        minSdk = 26
        targetSdk = 35
        versionCode = 4
        versionName = "1.0"
    }
    signingConfigs {
        if (cleEnvoi.isNotEmpty()) {
            create("upload") {
                storeFile = rootProject.file(cleEnvoi["storeFile"] as String)
                storePassword = cleEnvoi["storePassword"] as String
                keyAlias = cleEnvoi["keyAlias"] as String
                keyPassword = cleEnvoi["keyPassword"] as String
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            // Play refuse une signature debug : la clé d'envoi dès qu'elle
            // est présente, debug sinon (poste sans secret).
            signingConfig = if (cleEnvoi.isNotEmpty())
                signingConfigs.getByName("upload")
            else signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        // Pour lire VERSION_NAME depuis le code (en-tête User-Agent).
        buildConfig = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    // Carte 3D : MÊME moteur et MÊMES tuiles que l'iPhone et le web — une seule
    // vérité visuelle pour les trois surfaces.
    implementation("org.maplibre.gl:android-sdk:11.8.0")
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
}
