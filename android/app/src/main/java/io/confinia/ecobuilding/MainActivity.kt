package io.confinia.ecobuilding

import android.Manifest
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import org.maplibre.android.geometry.LatLng

/**
 * Écran unique — iso avec l'iPhone : la carte, et une fiche qui monte du bas.
 *
 * Pas d'écran d'accueil, pas de compte à créer, pas de tutoriel : tout ce qui
 * s'interpose entre le lancement et la première information fait renoncer.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme(colorScheme = darkColorScheme()) { Screen() } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Screen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var search by remember { mutableStateOf("") }
    var suggestions by remember { mutableStateOf<List<Suggestion>>(emptyList()) }
    var target by remember { mutableStateOf<Target?>(null) }
    var highlighted by remember { mutableStateOf<String?>(null) }
    var armed by remember { mutableStateOf<String?>(null) }
    var focus by remember { mutableStateOf<LatLng?>(null) }
    var pin by remember { mutableStateOf<LatLng?>(null) }
    var aerial by remember { mutableStateOf(false) }
    var quota by remember { mutableStateOf<Quota?>(null) }
    var report by remember { mutableStateOf<java.io.File?>(null) }
    var located by remember { mutableStateOf(UserLocation.granted(context)) }
    val model = remember(target) { BuildingModel() }

    // La position sert à ouvrir la carte là où l'utilisateur se trouve : sans
    // ça, il atterrit sur la France entière et doit chercher son quartier à la
    // main avant même de voir un bâtiment.
    val askLocation = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()) { granted -> located = granted }
    LaunchedEffect(Unit) {
        if (!UserLocation.granted(context)) {
            askLocation.launch(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }
    LaunchedEffect(located) {
        // Une adresse déjà cherchée l'emporte : on ne ramène pas la caméra.
        if (located && focus == null) {
            UserLocation.once(context) { point -> if (focus == null) focus = point }
        }
    }

    LaunchedEffect(Unit) { quota = runCatching { Api.quota(context) }.getOrNull() }
    LaunchedEffect(target) {
        target?.let { model.load(context, it) { id -> highlighted = id } }
    }

    Box(Modifier.fillMaxSize()) {
        BuildingMap(
            modifier = Modifier.fillMaxSize(),
            aerial = aerial, showUser = located, pin = pin,
            highlighted = highlighted, focus = focus,
            onArmed = { armed = it },
            onSelect = { id, point ->
                armed = null; highlighted = id; focus = null; pin = point
                target = Target.Building(id, point.longitude, point.latitude)
            })

        // Bascule plan / photo, SOUS la recherche et masquée pendant la saisie :
        // elle recouvrait la suggestion la plus probable.
        if (suggestions.isEmpty()) {
            Box(Modifier.align(Alignment.TopEnd).statusBarsPadding()
                .padding(top = 84.dp, end = 12.dp)) {
                FilledTonalIconButton(onClick = { aerial = !aerial },
                    modifier = Modifier.size(44.dp).clip(CircleShape)) {
                    Icon(if (aerial) Icons.Filled.Map else Icons.Filled.Public,
                        contentDescription = if (aerial) "Afficher le plan"
                                             else "Afficher la photo aérienne")
                }
            }
        }

        // Sans ces marges, le champ passait SOUS la barre d'état : l'heure
        // traversait le texte saisi.
        Column(Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(12.dp)) {
            OutlinedTextField(
                value = search, onValueChange = { search = it },
                placeholder = { Text("Adresse en France…") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
                // La loupe était une simple image sur iPhone : la toucher ne
                // faisait rien. Ici elle lance vraiment la recherche.
                leadingIcon = {
                    IconButton(onClick = { submit(search)?.let { t -> target = t
                        focus = null; search = ""; suggestions = emptyList() } }) {
                        Icon(Icons.Filled.Search, contentDescription = "Rechercher")
                    }
                },
                trailingIcon = {
                    if (search.isNotEmpty()) {
                        IconButton(onClick = { search = ""; suggestions = emptyList() }) {
                            Icon(Icons.Filled.Close, contentDescription = "Effacer")
                        }
                    }
                },
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                    imeAction = androidx.compose.ui.text.input.ImeAction.Search),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                    onSearch = { submit(search)?.let { t -> target = t
                        focus = null; search = ""; suggestions = emptyList() } }))
            suggestions.forEach { s ->
                Surface(tonalElevation = 3.dp) {
                    ListItem(
                        headlineContent = { Text(s.label) },
                        modifier = Modifier.fillMaxWidth().clickable {
                            // Vider le champ, et non y recopier l'adresse : la
                            // recopie relançait une recherche qui réaffichait la
                            // liste qu'on venait de fermer.
                            search = ""; suggestions = emptyList()
                            focus = LatLng(s.lat, s.lon)
                            pin = LatLng(s.lat, s.lon)
                            target = s.banId?.let { Target.Chosen(it, s.lon, s.lat, s.label) }
                                ?: Target.FreeText(s.label)
                        })
                }
            }
        }

        // Sans ce mot, le premier appui paraît sans effet.
        if (armed != null) {
            Surface(Modifier.align(Alignment.BottomCenter).navigationBarsPadding()
                .padding(bottom = 40.dp),
                shape = MaterialTheme.shapes.extraLarge, tonalElevation = 4.dp) {
                Text("Touchez à nouveau ce bâtiment pour voir sa fiche",
                    Modifier.padding(horizontal = 16.dp, vertical = 10.dp), fontSize = 14.sp)
            }
        }

        // Toucher la version copie l'identifiant d'installation. C'est ce que
        // le bêta-testeur envoie pour être exempté de quota : sans ce geste, il
        // faudrait le lui extraire de l'appareil, ce qu'aucun partenaire ne fera.
        var copied by remember { mutableStateOf(false) }
        Text(if (copied) "Identifiant copié" else versionLabel(context),
            fontSize = 10.sp, color = Color.Gray,
            modifier = Modifier.align(Alignment.BottomEnd).navigationBarsPadding()
                .padding(12.dp)
                .clickable {
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE)
                        as android.content.ClipboardManager
                    clipboard.setPrimaryClip(android.content.ClipData.newPlainText(
                        "EcoBuilding", InstallId.get(context)))
                    copied = true
                })
    }

    // Anti-rebond : une frappe ne doit pas déclencher une requête par lettre.
    LaunchedEffect(search) {
        if (search.length < 3) { suggestions = emptyList(); return@LaunchedEffect }
        delay(250)
        suggestions = runCatching { Api.suggest(context, search) }.getOrDefault(emptyList())
    }

    // La fiche PDF recouvre TOUT, comme sur iPhone : on ne quitte plus l'app
    // pour lire ce qu'on vient d'obtenir.
    report?.let { file ->
        PdfViewer(file, onClose = { report = null })
        androidx.activity.compose.BackHandler { report = null }
    }

    if (target != null) {
        // Ouverture pleine hauteur : à mi-hauteur, Android place le contenu sous
        // le pli et le bouton PDF n'est atteignable qu'après avoir tiré la
        // feuille. C'est l'objet vendu : il doit être là d'emblée.
        ModalBottomSheet(onDismissRequest = { target = null },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
            BuildingSheet(model, quota, onClose = { target = null },
                onQuotaChanged = { quota = it }, onReport = { report = it })
        }
    }
}

/** Recherche au texte tel quel : le serveur résout l'adresse lui-même. */
private fun submit(query: String): Target? =
    query.trim().takeIf { it.length >= 3 }?.let { Target.FreeText(it) }

/** « v1.0 (1) » : un testeur qui signale un plantage sans savoir ce qui tourne
 *  sur son téléphone coûte un aller-retour à chaque fois. */
private fun versionLabel(context: Context): String {
    val info = context.packageManager.getPackageInfo(context.packageName, 0)
    return "v${info.versionName} (${info.longVersionCode})"
}
