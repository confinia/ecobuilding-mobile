package io.confinia.ecobuilding

import android.content.Context
import android.content.Intent
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
import androidx.core.content.FileProvider
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
fun ReportButton(model: BuildingModel, quota: Quota?, onQuotaChanged: (Quota?) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var running by remember { mutableStateOf(false) }
    var elapsed by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(running) {
        elapsed = 0
        while (running && isActive) { delay(1000); elapsed += 1 }
    }

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
            onClick = {
                val id = model.buildingId ?: return@Button
                error = null
                running = true
                scope.launch {
                    try {
                        val file = Api.report(context, id, model.lon, model.lat)
                        openPdf(context, file)
                        onQuotaChanged(runCatching { Api.quota(context) }.getOrNull())
                    } catch (e: ReportError) {
                        // Le serveur sait pourquoi il refuse (limite atteinte,
                        // paiement requis) : son message vaut mieux que le nôtre.
                        error = e.detail.ifBlank { "La fiche n'a pas pu être générée. Réessayez." }
                    } catch (e: Exception) {
                        error = "La fiche n'a pas pu être générée. Réessayez."
                    } finally {
                        running = false
                    }
                }
            },
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

/**
 * Ouvre la fiche dans le lecteur PDF du téléphone.
 *
 * Le fichier passe par un FileProvider : depuis Android 7, transmettre un
 * `file://` à une autre application lève une exception. Et sans lecteur PDF
 * installé — c'est le cas d'origine sur beaucoup d'appareils — on propose le
 * partage, qui permet au moins d'envoyer ou d'enregistrer la fiche plutôt que
 * de laisser l'utilisateur devant un échec muet.
 */
private fun openPdf(context: Context, file: File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val view = Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, "application/pdf")
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    if (view.resolveActivity(context.packageManager) != null) {
        context.startActivity(view)
        return
    }
    val share = Intent(Intent.ACTION_SEND)
        .setType("application/pdf")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(share, "Ouvrir la fiche PDF")
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}
