package io.confinia.ecobuilding

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.*

/** Cible de la fiche : bâtiment touché, suggestion choisie, ou texte libre. */
sealed interface Target {
    data class Building(val id: String, val lon: Double, val lat: Double) : Target
    data class Chosen(val banId: String, val lon: Double, val lat: Double, val label: String) : Target
    data class FreeText(val query: String) : Target
}

/**
 * Fiche d'un bâtiment, remplie AU FIL DE L'EAU — iso avec l'iPhone.
 *
 * Le serveur émet le bâtiment dès que la BDNB a répondu (~0,6 s), puis un
 * événement par source. On affiche donc immédiatement ce qu'on sait, et on
 * complète, au lieu d'attendre la source la plus lente (plus de 5 s).
 */
class BuildingModel {
    var address by mutableStateOf<String?>(null)
    var searched by mutableStateOf<String?>(null)
    var building by mutableStateOf<JsonObject?>(null)
    var blocks = mutableStateMapOf<String, JsonElement>()
    var pending = mutableStateOf(EXPECTED.toSet())
    var failure by mutableStateOf<String?>(null)
    var lon: Double? = null
    var lat: Double? = null

    val buildingId: String? get() = building?.get("bdnb_id")?.jsonPrimitive?.contentOrNull

    companion object {
        val EXPECTED = listOf("area_risks", "groundwater", "solar_pv", "water_network",
            "official_dpe", "local_taxes", "schools", "prices", "rnb")
        val LABELS = mapOf(
            "area_risks" to "Risques", "groundwater" to "Nappe phréatique",
            "solar_pv" to "Solaire", "water_network" to "Eau potable",
            "official_dpe" to "DPE officiel", "local_taxes" to "Fiscalité locale",
            "schools" to "Écoles", "prices" to "Prix de vente", "rnb" to "ID-RNB")
    }

    suspend fun load(context: Context, target: Target, onResolved: (String) -> Unit) {
        val flow = when (target) {
            is Target.Building -> { lon = target.lon; lat = target.lat
                Api.buildingStream(context, target.id, target.lon, target.lat) }
            is Target.Chosen -> { lon = target.lon; lat = target.lat
                searched = target.label; address = target.label
                Api.lookupStream(context, target.banId, target.lon, target.lat) }
            is Target.FreeText -> { searched = target.query; address = target.query
                Api.lookupStream(context, target.query) }
        }
        try {
            flow.collect { event ->
                when (event) {
                    is StreamEvent.Core -> {
                        address = event.query["address"]?.jsonPrimitive?.contentOrNull ?: address
                        building = event.buildings.firstOrNull()?.jsonObject
                        buildingId?.let(onResolved)
                    }
                    is StreamEvent.Block -> {
                        blocks[event.name] = event.value
                        pending.value = pending.value - event.name
                    }
                    is StreamEvent.Done -> {
                        address = event.query["address"]?.jsonPrimitive?.contentOrNull ?: address
                        pending.value = emptySet()
                    }
                    is StreamEvent.Failure -> {
                        failure = if (event.status == 404) "Pas de fiche pour ce bâtiment."
                                  else "Données momentanément indisponibles."
                        pending.value = emptySet()
                    }
                }
            }
        } catch (e: Exception) {
            // Réseau coupé : on garde ce qui est affiché et on le dit, plutôt
            // que de vider l'écran.
            if (building == null) failure = "Données momentanément indisponibles."
            pending.value = emptySet()
        }
    }
}

private fun JsonElement?.str(key: String): String? =
    this?.jsonObject?.get(key)?.jsonPrimitive?.contentOrNull

private fun JsonElement?.num(key: String): Double? =
    this?.jsonObject?.get(key)?.jsonPrimitive?.doubleOrNull

private fun dpeColor(cls: String?) = when (cls) {
    "A" -> Color(0f, 0.56f, 0.21f); "B" -> Color(0.32f, 0.69f, 0.33f)
    "C" -> Color(0.65f, 0.80f, 0.45f); "D" -> Color(0.96f, 0.91f, 0.06f)
    "E" -> Color(0.94f, 0.71f, 0.06f); "F" -> Color(0.92f, 0.51f, 0.21f)
    "G" -> Color(0.84f, 0.13f, 0.12f); else -> Color.Gray
}

@Composable
fun BuildingSheet(model: BuildingModel, quota: Quota?, onClose: () -> Unit,
                  onQuotaChanged: (Quota?) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Column(
            Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Text(model.searched ?: model.address ?: "Bâtiment",
                    modifier = Modifier.weight(1f),
                    fontSize = 20.sp, fontWeight = FontWeight.Bold)
                // Une CROIX, pas le mot « Fermer » : revenir à la carte se
                // cherchait, et c'est le geste le plus fréquent de l'app.
                IconButton(onClick = onClose, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = "Fermer la fiche")
                }
            }
            // Un « bâtiment groupe » BDNB couvre parfois plusieurs adresses :
            // le dire, plutôt que de laisser croire à une erreur.
            val principal = model.address
            if (principal != null && model.searched != null &&
                !principal.equals(model.searched, ignoreCase = true)) {
                Text("Adresse principale du bâtiment : $principal",
                    fontSize = 12.sp, color = Color.Gray)
            }

            val failure = model.failure
            val b = model.building
            when {
                failure != null -> Text(failure, color = Color.Gray)
                b == null -> CircularProgressIndicator()
                else -> {
                    EnergySection(b, model.blocks["official_dpe"])
                    Section("Bâtiment") {
                        Row("Année de construction", b.num("construction_year")?.toInt()?.toString())
                        Row("Hauteur", b.num("height_m")?.let { "${it.toInt()} m" })
                        // « Niveaux » et non « Étages » : en français, « 1 étage »
                        // se comprend comme rez-de-chaussée + 1. Et à un seul
                        // niveau, on dit « de plain-pied » — critère décisif
                        // pour qui vieillit ou vit avec un handicap.
                        Row("Niveaux", b.num("floors")?.toInt()?.let {
                            if (it == 1) "1 — de plain-pied" else it.toString() })
                        Row("Logements", b.num("dwellings")?.toInt()?.toString())
                        Row("Murs", b.str("wall_material")?.capitalize())
                        Row("Toiture", b.str("roof_material")?.capitalize())
                    }
                    RisksSection(model.blocks["area_risks"])
                    EnvironmentSection(model.blocks["groundwater"], model.blocks["solar_pv"],
                        model.blocks["water_network"])
                    NeighbourhoodSection(model.blocks["local_taxes"], model.blocks["schools"],
                        model.blocks["prices"])
                    Section("Identifiants") {
                        Row("ID-RNB", model.blocks["rnb"].str("rnb_id"))
                        Row("ID BDNB", b.str("bdnb_id"))
                    }
                }
            }

            if (model.pending.value.isNotEmpty()) {
                Text("Encore en cours : " + model.pending.value
                    .mapNotNull { BuildingModel.LABELS[it] }.sorted().joinToString(", ") + "…",
                    fontSize = 12.sp, color = Color.Gray)
            }
        }

        // Bouton ANCRÉ, hors du défilement : il n'apparaissait qu'après avoir
        // fait défiler toute la fiche, alors que c'est l'objet vendu.
        if (model.building != null) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
                ReportButton(model, quota, onQuotaChanged)
            }
        }
    }
}

/**
 * Ce qu'on affiche sous le bouton. Même formulation que l'iPhone : un mur doit
 * dire ce qui a été consommé ET quand il rouvre, sinon il ressemble à une panne
 * définitive.
 */
fun quotaLine(q: Quota?, building: String?): String? {
    if (q == null) return null
    if (building != null && building in q.freeAgain)
        return "Déjà obtenue aujourd'hui — nouveau téléchargement gratuit"
    val left = q.reportsLeft ?: return null
    val whenTxt = when (q.period) { "month" -> "ce mois-ci"; "day" -> "aujourd'hui"; else -> "" }
    val total = q.reportsIncluded?.toString() ?: "?"
    var text = if (left == 0) {
        "Limite atteinte : ${q.reportsUsed} bâtiments sur $total $whenTxt" +
            (reopensIn(q.resetsAt)?.let { " — elle repart $it" } ?: "")
    } else {
        val suffix = if (whenTxt.isEmpty()) " sur $total" else " $whenTxt sur $total"
        if (left > 1) "$left bâtiments restants$suffix" else "1 bâtiment restant$suffix"
    }
    if (q.units > 0) text += " · ${q.units} à l'unité"
    return text
}

/** « dans 3 heures » : « demain » ne dit rien à 23 h 50. */
private fun reopensIn(iso: String?): String? {
    val at = runCatching { java.time.OffsetDateTime.parse(iso) }.getOrNull() ?: return null
    val seconds = java.time.Duration.between(java.time.OffsetDateTime.now(), at).seconds
    if (seconds <= 0) return null
    if (seconds < 3600) {
        val m = (seconds / 60).coerceAtLeast(1)
        return "dans $m minute" + if (m > 1) "s" else ""
    }
    val h = seconds / 3600
    return "dans $h heure" + if (h > 1) "s" else ""
}

@Composable
private fun EnergySection(b: JsonObject, officialDpe: JsonElement?) {
    val energy = b["energy"]
    val cls = energy.str("dpe_class")
    Section("Énergie") {
        Row(Modifier.padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)).background(dpeColor(cls)),
                contentAlignment = Alignment.Center) {
                Text(cls ?: "?", color = Color.White,
                    fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(12.dp))
            Column {
                // Un « ? » nu n'explique rien : on dit ce qu'il signifie.
                Text(cls?.let { "Classe DPE $it" } ?: "DPE non renseigné",
                    fontWeight = FontWeight.Medium)
                if (cls == null) {
                    Text("Aucun diagnostic publié pour ce bâtiment",
                        fontSize = 12.sp, color = Color.Gray)
                } else energy.num("consumption_kwh_m2y")?.let {
                    Text("${it.toInt()} kWh/m²/an", fontSize = 12.sp, color = Color.Gray)
                }
            }
        }
        energy?.jsonObject?.get("rental_ban").str("rental_ban_date")?.let {
            Text("⚠ Location interdite à partir de ${it.take(4)} (loi Climat et Résilience)",
                color = Color(0.9f, 0.5f, 0.1f), fontSize = 14.sp)
        }
        Row("GES", energy.num("ghg_kgco2_m2y")?.let { "${it.toInt()} kgCO₂/m²/an" })
        Row("Date du DPE", energy.str("dpe_date")?.take(10))
        Row("N° DPE officiel", officialDpe.str("dpe_number"))
        Row("Surface habitable", officialDpe.num("surface_habitable_m2")?.let { "${it.toInt()} m²" })
        Row("Coût annuel d'énergie", officialDpe.num("annual_cost_eur")?.let { "${it.toInt()} €/an" })
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.Gray)
        content()
    }
}

/** Une valeur absente disparaît : une fiche pleine de tirets paraît vide. */
@Composable
private fun Row(label: String, value: String?) {
    if (value != null) {
        Row(Modifier.fillMaxWidth()) {
            Text(label, color = Color.Gray, fontSize = 14.sp)
            Spacer(Modifier.weight(1f))
            Text(value, fontSize = 14.sp)
        }
    }
}

@Composable
private fun RisksSection(risks: JsonElement?) {
    val natural = risks.strings("risques_naturels")
    val techno = risks.strings("risques_technologiques")
    if (natural.isEmpty() && techno.isEmpty()) return
    Section("Risques (Géorisques)") {
        if (natural.isNotEmpty()) Row("Naturels", natural.joinToString(", ", transform = ::humanize))
        if (techno.isNotEmpty()) Row("Technologiques", techno.joinToString(", ", transform = ::humanize))
        Row("Argiles", risks.str("clay_shrink_swell"))
    }
}

/**
 * Les clés de Géorisques arrivent en langage machine
 * (« retraitGonflementArgile ») : personne ne doit lire ça dans une fiche.
 */
private val RISK_NAMES = mapOf(
    "inondation" to "Inondation", "remonteeNappe" to "Remontée de nappe",
    "seisme" to "Séisme", "mouvementTerrain" to "Mouvement de terrain",
    "retraitGonflementArgile" to "Retrait-gonflement des argiles",
    "feuForet" to "Feu de forêt", "radon" to "Radon", "icpe" to "ICPE",
    "pollutionSols" to "Pollution des sols", "nucleaire" to "Nucléaire",
    "ruptureBarrage" to "Rupture de barrage", "risqueMinier" to "Risque minier",
    "cavite" to "Cavité souterraine", "avalanche" to "Avalanche",
    "canalisationsMatieresDangereuses" to "Canalisations (matières dangereuses)",
)

private fun humanize(key: String): String = RISK_NAMES[key]
    ?: key.replace(Regex("([a-z])([A-Z])"), "$1 $2").replaceFirstChar { it.uppercase() }

@Composable
private fun EnvironmentSection(groundwater: JsonElement?, solar: JsonElement?, water: JsonElement?) {
    val depth = groundwater.num("depth_m")
    val yield_ = solar.num("yield_kwh_per_kwc_y")
    val efficiency = water.num("efficiency_pct")
    if (depth == null && yield_ == null && efficiency == null) return
    Section("Environnement") {
        Row("Nappe phréatique", depth?.let { fmt("%.1f m", it) })
        Row("Productible solaire", yield_?.let { "${it.toInt()} kWh/an par kWc" })
        Row("Rendement du réseau d'eau", efficiency?.let { fmt("%.1f %%", it) })
        Row("Prix de l'eau", water.num("price_eur_m3")?.let { fmt("%.2f €/m³", it) })
    }
}

@Composable
private fun NeighbourhoodSection(taxes: JsonElement?, schools: JsonElement?, prices: JsonElement?) {
    val medians = prices?.jsonObject?.get("commune_eur_m2")?.jsonObject ?: JsonObject(emptyMap())
    val nbSchools = (schools as? JsonArray)?.size ?: 0
    val tax = taxes.num("property_tax_built_pct")
    if (medians.isEmpty() && nbSchools == 0 && tax == null) return
    Section("Quartier") {
        medians.keys.sorted().forEach { k ->
            Row("Médiane ${k.lowercase()}",
                medians[k].num("median")?.toInt()?.let { "$it €/m²" })
        }
        Row("Taxe foncière (bâti)", tax?.let { fmt("%.2f %%", it) })
        Row("Ordures ménagères", taxes.num("waste_tax_pct")?.let { fmt("%.2f %%", it) })
        Row("Écoles à proximité", if (nbSchools > 0) "$nbSchools" else null)
    }
}

/** Format FRANÇAIS : la virgule décimale, pas le point. */
private fun fmt(pattern: String, value: Double): String =
    String.format(java.util.Locale.FRANCE, pattern, value)

private fun JsonElement?.strings(key: String): List<String> =
    (this?.jsonObject?.get(key) as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }
        ?: emptyList()

private fun String.capitalize(): String = replaceFirstChar { it.uppercase() }
