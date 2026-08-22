package io.confinia.ecobuilding

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Description
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * Obtenir la fiche PDF — **l'élément le plus visible de l'écran**.
 *
 * C'est l'objet que l'utilisateur emporte : celui qu'il envoie à un notaire, à
 * un artisan, ou qu'il garde avant une visite. Tout le reste de la fiche sert à
 * donner envie de l'obtenir ; ce bouton ne doit donc jamais être une ligne
 * discrète en bas d'écran.
 *
 * La génération prend 10 à 45 s côté serveur (données, rendu 3D, mise en page).
 * On annonce les étapes réelles plutôt qu'une barre de progression lisse, qui
 * serait une fiction : un rendu serveur unique n'expose aucune progression.
 */
@Composable
fun ReportButton(model: BuildingModel, quota: Quota?, onQuotaChanged: (Quota?) -> Unit,
                 onReport: (File) -> Unit,
                 autoStart: Boolean = false, onAutoStarted: () -> Unit = {}) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var running by remember { mutableStateOf(false) }
    var elapsed by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(running) {
        elapsed = 0
        while (running && isActive) { delay(1000); elapsed += 1 }
    }

    // Le téléchargement est décrit une seule fois : le bouton l'appelle, et le
    // double appui sur la carte aussi. Deux copies auraient divergé.
    val start = {
        val id = model.buildingId
        if (id != null && !running) {
            error = null
            running = true
            scope.launch {
                try {
                    val file = Api.report(context, id, model.lon, model.lat)
                    onReport(file)
                    onQuotaChanged(runCatching { Api.quota(context) }.getOrNull())
                } catch (e: ReportError) {
                    error = e.detail.ifBlank { "La fiche n'a pas pu être générée. Réessayez." }
                } catch (e: Exception) {
                    error = "La fiche n'a pas pu être générée. Réessayez."
                } finally {
                    running = false
                }
            }
        }
    }

    // Double appui sur la carte : la fiche part dès que le bâtiment a répondu.
    LaunchedEffect(autoStart, model.buildingId) {
        if (autoStart && model.buildingId != null) { onAutoStarted(); start() }
    }

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
            onClick = { start() },
            enabled = !running && model.buildingId != null,
            modifier = Modifier.fillMaxWidth().height(52.dp),
            // La couleur du TEXTE doit être dite : sans elle, Material peint le
            // libellé dans la teinte du thème — du violet sur du vert, illisible.
            colors = ButtonDefaults.buttonColors(
                containerColor = Color(0.17f, 0.48f, 0.29f), contentColor = Color.White),
        ) {
            Icon(if (running) Icons.Filled.Autorenew else Icons.Filled.Description,
                contentDescription = null)
            Spacer(Modifier.width(10.dp))
            Text(if (running) stageLabel(elapsed) else "Obtenir la fiche PDF",
                fontWeight = FontWeight.SemiBold)
            if (running) {
                Spacer(Modifier.weight(1f))
                Text("$elapsed s", fontSize = 12.sp)
            }
        }

        val message = error ?: quotaLine(quota, model.buildingId)
        if (message != null) {
            // Dire ce qu'il reste AVANT d'en manquer : on découvrait la limite
            // en la heurtant. Aucun prix affiché tant que le mur payant n'existe
            // pas — annoncer un tarif qu'on ne peut pas encaisser serait faux.
            Text(message, fontSize = 12.sp,
                color = if (error != null || quota?.reportsLeft == 0)
                    Color(0.9f, 0.5f, 0.1f) else Color.Gray)
        }
    }
}

/** Étapes calées sur les durées réelles observées côté serveur. */
private fun stageLabel(elapsed: Int): String = when {
    elapsed < 3 -> "Collecte des données…"
    elapsed < 12 -> "Rendu de la carte 3D…"
    else -> "Mise en page…"
}
