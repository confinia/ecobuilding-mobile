package io.confinia.ecobuilding

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Lecteur de fiche PDF INTÉGRÉ à l'application.
 *
 * Confier le document à une autre application revenait à perdre l'utilisateur
 * juste après l'action la plus importante du produit : sur un téléphone neuf,
 * aucun lecteur PDF n'est installé et il tombait sur un sélecteur de partage.
 * Même avec un lecteur, on quittait l'app pour voir ce qu'on venait d'obtenir.
 *
 * `PdfRenderer` est fourni par le système depuis Android 5 : pas de
 * bibliothèque tierce, pas de services Google — même choix que pour la carte et
 * la position.
 */
@Composable
fun PdfViewer(file: File, onClose: () -> Unit) {
    val context = LocalContext.current
    val widthPx = with(LocalDensity.current) {
        LocalConfiguration.current.screenWidthDp.dp.roundToPx()
    }
    val document = remember(file) { PdfDocument(file) }
    DisposableEffect(document) { onDispose { document.close() } }

    Column(Modifier.fillMaxSize().background(Color(0.07f, 0.07f, 0.07f))) {
        Row(
            Modifier.fillMaxWidth().background(Color(0.12f, 0.12f, 0.12f))
                .statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Une CROIX, pas le mot « Fermer » : c'est le geste le plus fréquent
            // une fois la fiche lue.
            IconButton(onClick = onClose) {
                Icon(Icons.Filled.Close, contentDescription = "Fermer la fiche",
                    tint = Color.White)
            }
            Spacer(Modifier.weight(1f))
            // Le partage RESTE : c'est ce qui permet d'envoyer la fiche à un
            // client ou de l'enregistrer, sans obliger à passer par là pour la
            // simple lecture.
            IconButton(onClick = { share(context, file) }) {
                Icon(Icons.Filled.Share, contentDescription = "Partager la fiche",
                    tint = Color.White)
            }
        }

        val pages = document.pageCount
        if (pages == 0) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("La fiche n'a pas pu être ouverte.", color = Color.Gray)
            }
            return@Column
        }

        LazyColumn(
            Modifier.fillMaxSize().navigationBarsPadding(),
            contentPadding = PaddingValues(vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items((0 until pages).toList()) { index ->
                // Rendu À LA DEMANDE : une page A4 en pleine largeur pèse
                // plusieurs mégaoctets, et les rendre toutes d'un coup fait
                // tomber l'app sur une fiche de quelques pages.
                val bitmap by produceState<Bitmap?>(null, index, widthPx) {
                    value = document.render(index, widthPx)
                }
                val ratio = document.ratio(index)
                Box(
                    Modifier.fillMaxWidth().padding(horizontal = 8.dp)
                        .aspectRatio(ratio).background(Color.White),
                    contentAlignment = Alignment.Center,
                ) {
                    bitmap?.let {
                        Image(it.asImageBitmap(), contentDescription = "Page ${index + 1}",
                            modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                    } ?: CircularProgressIndicator()
                }
            }
        }
    }
}

/**
 * Accès sérialisé au document.
 *
 * `PdfRenderer` n'accepte **qu'une page ouverte à la fois** : deux rendus
 * concurrents — ce que fait naturellement une liste qui défile — lèvent une
 * exception. D'où le verrou.
 */
private class PdfDocument(file: File) {
    private val mutex = Mutex()
    private var descriptor: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null
    private val ratios = mutableMapOf<Int, Float>()

    val pageCount: Int

    init {
        var count = 0
        runCatching {
            val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val r = PdfRenderer(fd)
            descriptor = fd
            renderer = r
            count = r.pageCount
        }
        pageCount = count
    }

    /** Rapport largeur/hauteur, pour réserver la place avant même le rendu. */
    fun ratio(index: Int): Float = ratios[index] ?: 0.707f   // A4 par défaut

    suspend fun render(index: Int, widthPx: Int): Bitmap? = withContext(Dispatchers.IO) {
        mutex.withLock {
            val r = renderer ?: return@withLock null
            runCatching {
                r.openPage(index).use { page ->
                    val ratio = page.width.toFloat() / page.height
                    ratios[index] = ratio
                    val height = (widthPx / ratio).toInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(widthPx, height, Bitmap.Config.ARGB_8888)
                    // Fond blanc explicite : un PDF ne peint pas son papier, et
                    // le texte noir apparaissait sur un fond transparent, donc
                    // illisible sur notre fond sombre.
                    bitmap.eraseColor(AndroidColor.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    bitmap
                }
            }.getOrNull()
        }
    }

    fun close() {
        runCatching { renderer?.close() }
        runCatching { descriptor?.close() }
        renderer = null
        descriptor = null
    }
}

private fun share(context: Context, file: File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val intent = Intent(Intent.ACTION_SEND)
        .setType("application/pdf")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(intent, "Partager la fiche PDF"))
}
