package io.confinia.ecobuilding

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.ui.platform.LocalContext
import java.io.File
import kotlinx.coroutines.launch
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
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

    /* Pourquoi il n'y a pas de bâtiment — et non « une erreur est survenue ».
     *
     * Sans ce champ, une adresse sans bâtiment BDNB laissait `failure` et
     * `building` tous deux nuls, et le rendu tombait sur l'indicateur de
     * chargement : la fiche tournait indéfiniment sur une adresse parfaitement
     * valide. C'est le cas de TOUTE l'outre-mer, où la BDNB n'a aucun bâtiment. */
    var sansBatiment by mutableStateOf<String?>(null)
    var lon: Double? = null
    var lat: Double? = null

    val buildingId: String? get() = (building?.get("bdnb_id") as? JsonPrimitive)?.contentOrNull

    companion object {
        val EXPECTED = listOf("area_risks", "groundwater", "solar_pv", "water_network",
            "official_dpe", "local_taxes", "schools", "prices", "rnb", "commune",
            "dpe_spread")
        /** Libellés des sources encore attendues, par identifiant de ressource
         *  et non en dur : ils s'affichent dans la langue du téléphone. */
        val LABELS = mapOf(
            "area_risks" to R.string.block_risks,
            "groundwater" to R.string.block_groundwater,
            "solar_pv" to R.string.block_solar,
            "water_network" to R.string.block_water,
            "official_dpe" to R.string.block_dpe,
            "local_taxes" to R.string.block_taxes,
            "schools" to R.string.block_schools,
            "prices" to R.string.block_prices,
            "rnb" to R.string.block_rnb,
            "commune" to R.string.block_commune,
            "dpe_spread" to R.string.block_dpe_spread)
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
                        address = (event.query["address"] as? JsonPrimitive)?.contentOrNull ?: address
                        building = event.buildings.firstOrNull() as? JsonObject
                        sansBatiment = if (building == null)
                            (event.noBuilding?.get("text") as? JsonPrimitive)?.contentOrNull
                                ?: context.getString(R.string.no_building_here)
                        else null
                        buildingId?.let(onResolved)
                    }
                    is StreamEvent.Block -> {
                        blocks[event.name] = event.value
                        pending.value = pending.value - event.name
                    }
                    is StreamEvent.Done -> {
                        address = (event.query["address"] as? JsonPrimitive)?.contentOrNull ?: address
                        pending.value = emptySet()
                    }
                    is StreamEvent.Failure -> {
                        failure = if (event.status == 404) context.getString(R.string.no_sheet)
                                  else context.getString(R.string.data_unavailable)
                        pending.value = emptySet()
                    }
                }
            }
        } catch (e: Exception) {
            // Réseau coupé : on garde ce qui est affiché et on le dit, plutôt
            // que de vider l'écran.
            if (building == null) failure = context.getString(R.string.data_unavailable)
            pending.value = emptySet()
        }
    }
}

/*
 * Accès TOLÉRANTS au JSON.
 *
 * Une source ouverte sur neuf renvoie régulièrement `null` : pas de DPE
 * officiel publié, pas de vente récente dans la commune, pas de réseau d'eau
 * renseigné. Le bloc arrive alors comme `JsonNull`, et `.jsonObject` lève une
 * exception — l'application entière tombait sur un bâtiment banal.
 *
 * D'où `as?` partout : une donnée absente doit faire disparaître une ligne, pas
 * l'écran.
 */
private fun JsonElement?.obj(key: String): JsonElement? =
    (this as? JsonObject)?.get(key)

private fun JsonElement?.str(key: String): String? =
    (this.obj(key) as? JsonPrimitive)?.contentOrNull

private fun JsonElement?.num(key: String): Double? =
    (this.obj(key) as? JsonPrimitive)?.doubleOrNull

private fun dpeColor(cls: String?) = when (cls) {
    "A" -> Color(0f, 0.56f, 0.21f); "B" -> Color(0.32f, 0.69f, 0.33f)
    "C" -> Color(0.65f, 0.80f, 0.45f); "D" -> Color(0.96f, 0.91f, 0.06f)
    "E" -> Color(0.94f, 0.71f, 0.06f); "F" -> Color(0.92f, 0.51f, 0.21f)
    "G" -> Color(0.84f, 0.13f, 0.12f); else -> Color.Gray
}

@Composable
fun BuildingSheet(model: BuildingModel, quota: Quota?, onClose: () -> Unit,
                  onQuotaChanged: (Quota?) -> Unit,
                  onReport: (java.io.File) -> Unit,
                  autoStart: Boolean = false, onAutoStarted: () -> Unit = {}) {
    // Hauteur BORNÉE, sinon le poids ne veut rien dire : la feuille mesurait son
    // contenu sans contrainte, la zone défilante prenait toute la place et le
    // bouton PDF tombait hors de l'écran — le défaut déjà corrigé sur iPhone,
    // reproduit ici parce qu'Android mesure autrement.
    val maxHeight = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp
    Column(Modifier.fillMaxWidth().heightIn(max = maxHeight * 0.88f)) {
        Column(
            Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Text(model.searched ?: model.address ?: stringResource(R.string.sheet_fallback_title),
                    modifier = Modifier.weight(1f),
                    fontSize = 20.sp, fontWeight = FontWeight.Bold)
                // Une CROIX, pas le mot « Fermer » : revenir à la carte se
                // cherchait, et c'est le geste le plus fréquent de l'app.
                IconButton(onClick = onClose, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.sheet_close))
                }
            }
            // Un « bâtiment groupe » BDNB couvre parfois plusieurs adresses :
            // le dire, plutôt que de laisser croire à une erreur.
            val principal = model.address
            if (principal != null && model.searched != null &&
                !principal.equals(model.searched, ignoreCase = true)) {
                Text(stringResource(R.string.main_address, principal),
                    fontSize = 12.sp, color = Color.Gray)
            }

            val failure = model.failure
            val b = model.building
            val sansBatiment = model.sansBatiment
            when {
                failure != null -> Text(failure, color = Color.Gray)
                // Le motif AVANT l'attente : sinon on tourne sur une adresse
                // dont on sait déjà qu'elle n'aura jamais de bâtiment.
                b == null && sansBatiment != null -> {
                    Text(sansBatiment, color = Color.Gray)
                    RisksSection(model.blocks["area_risks"])
                }
                b == null -> CircularProgressIndicator()
                else -> {
                    EnergySection(b, model.blocks["official_dpe"], model.blocks["dpe_spread"],
                        model = model, onReport = onReport)
                    val plainPied = stringResource(R.string.single_storey)
                    Section(stringResource(R.string.section_building)) {
                        Row(stringResource(R.string.build_year), b.num("construction_year")?.toInt()?.toString())
                        Row(stringResource(R.string.height), b.num("height_m")?.let { stringResource(R.string.unit_metres, it.toInt()) })
                        // « Niveaux » et non « Étages » : en français, « 1 étage »
                        // se comprend comme rez-de-chaussée + 1. Et à un seul
                        // niveau, on dit « de plain-pied » — critère décisif
                        // pour qui vieillit ou vit avec un handicap.
                        Row(stringResource(R.string.levels), b.num("floors")?.toInt()?.let {
                            if (it == 1) plainPied else it.toString() })
                        Row(stringResource(R.string.dwellings), b.num("dwellings")?.toInt()?.toString())
                        Row(stringResource(R.string.walls), b.str("wall_material")?.capitalize())
                        Row(stringResource(R.string.roof), b.str("roof_material")?.capitalize())
                    }
                    RisksSection(model.blocks["area_risks"])
                    EnvironmentSection(model.blocks["groundwater"], model.blocks["solar_pv"],
                        model.blocks["water_network"])
                    NeighbourhoodSection(model.blocks["local_taxes"], model.blocks["schools"],
                        model.blocks["prices"])
                    CommuneSection(model.blocks["commune"])
                    Section(stringResource(R.string.section_ids)) {
                        Row(stringResource(R.string.id_rnb), model.blocks["rnb"].str("rnb_id"))
                        Row(stringResource(R.string.id_bdnb), b.str("bdnb_id"))
                    }
                }
            }

            if (model.pending.value.isNotEmpty()) {
                Text(stringResource(R.string.pending_prefix) + model.pending.value
                    .mapNotNull { BuildingModel.LABELS[it] }
                    .map { stringResource(it) }.sorted().joinToString(", ") + "…",
                    fontSize = 12.sp, color = Color.Gray)
            }
        }

        // Bouton ANCRÉ, hors du défilement : il n'apparaissait qu'après avoir
        // fait défiler toute la fiche, alors que c'est l'objet vendu.
        if (model.building != null) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp)) {
                ReportButton(model, quota, onQuotaChanged, onReport, autoStart, onAutoStarted)
            }
        }
    }
}

/**
 * Ce qu'on affiche sous le bouton. Même formulation que l'iPhone : un mur doit
 * dire ce qui a été consommé ET quand il rouvre, sinon il ressemble à une panne
 * définitive.
 */
fun quotaLine(ctx: Context, q: Quota?, building: String?): String? {
    if (q == null) return null
    if (building != null && building in q.freeAgain) return ctx.getString(R.string.quota_cached)
    val total = q.reportsIncluded ?: return null
    val quand = when (q.period) {
        "month" -> ctx.getString(R.string.quota_month)
        "day" -> ctx.getString(R.string.quota_today)
        else -> ""
    }
    // CONSOMMATION, et non solde restant : « 10 bâtiments restants sur 10 » se
    // lisait comme un compteur déjà plein, et alarmait avant le premier usage.
    var texte = if (q.reportsLeft == 0) {
        ctx.getString(R.string.quota_full, total) +
            (reopensIn(ctx, q.resetsAt)?.let { ctx.getString(R.string.quota_reopens, it) } ?: "")
    } else {
        ctx.getString(R.string.quota_used, q.reportsUsed, total) +
            if (quand.isEmpty()) "" else " $quand"
    }
    if (q.units > 0) texte += ctx.getString(R.string.quota_units, q.units)
    return texte
}

/** « dans 3 heures » : « demain » ne dit rien à 23 h 50. */
private fun reopensIn(ctx: Context, iso: String?): String? {
    val at = runCatching { java.time.OffsetDateTime.parse(iso) }.getOrNull() ?: return null
    val secondes = java.time.Duration.between(java.time.OffsetDateTime.now(), at).seconds
    if (secondes <= 0) return null
    if (secondes < 3600) {
        val m = (secondes / 60).coerceAtLeast(1).toInt()
        return ctx.getString(if (m > 1) R.string.in_minutes_plural else R.string.in_minutes, m)
    }
    val h = (secondes / 3600).toInt()
    return ctx.getString(if (h > 1) R.string.in_hours_plural else R.string.in_hours, h)
}

@Composable
private fun EnergySection(b: JsonObject, officialDpe: JsonElement?, spread: JsonElement? = null,
                          model: BuildingModel? = null, onReport: (File) -> Unit = {}) {
    val energy = b["energy"]
    val cls = energy.str("dpe_class")
    /* Le badge dit l'ÉVENTAIL quand les logements de l'immeuble diffèrent.
     *
     * Une grosse lettre colorée a l'air catégorique, et le lecteur pressé ne
     * voit qu'elle. Mesuré : dès qu'une adresse porte plusieurs diagnostics,
     * deux fois sur trois les classes diffèrent — la lettre affirmait donc une
     * certitude fausse pour presque tous les logements. */
    val basse = spread.str("classe_min")
    val haute = spread.str("classe_max")
    val identiques = (spread.obj("identiques") as? JsonPrimitive)?.booleanOrNull ?: true
    val eventail = !identiques && basse != null && haute != null
    Section(stringResource(R.string.section_energy)) {
        Row(Modifier.padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(10.dp))
                    .then(if (eventail)
                        Modifier.background(Brush.linearGradient(
                            listOf(dpeColor(basse), dpeColor(haute))))
                    else Modifier.background(dpeColor(cls))),
                contentAlignment = Alignment.Center) {
                Text(if (eventail) "$basse–$haute" else (cls ?: "?"), color = Color.White,
                    fontSize = if (eventail) 13.sp else 20.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(12.dp))
            Column {
                // Un « ? » nu n'explique rien : on dit ce qu'il signifie.
                Text(cls?.let { stringResource(R.string.dpe_class, it) }
                        ?: stringResource(R.string.dpe_missing),
                    fontWeight = FontWeight.Medium)
                if (eventail) {
                    Text(stringResource(R.string.dpe_spread_range,
                            (spread.num("diagnostics") ?: 0.0).toInt(), basse!!, haute!!),
                        fontSize = 11.sp, color = Color.Gray)
                }
                if (cls == null) {
                    Text(stringResource(R.string.dpe_none_published),
                        fontSize = 12.sp, color = Color.Gray)
                } else energy.num("consumption_kwh_m2y")?.let {
                    Text(stringResource(R.string.unit_kwh_m2y, it.toInt()), fontSize = 12.sp, color = Color.Gray)
                }
            }
        }
        energy.obj("rental_ban").str("rental_ban_date")?.let {
            Text(stringResource(R.string.rental_ban, it.take(4)),
                color = Color(0.9f, 0.5f, 0.1f), fontSize = 14.sp)
        }
        Row(stringResource(R.string.ghg), energy.num("ghg_kgco2_m2y")?.let { stringResource(R.string.unit_ghg, it.toInt()) })
        Row(stringResource(R.string.dpe_date), energy.str("dpe_date")?.take(10))
        Row(stringResource(R.string.dpe_number), officialDpe.str("dpe_number"))
        Row(stringResource(R.string.living_area), officialDpe.num("surface_habitable_m2")?.let { stringResource(R.string.unit_m2, it.toInt()) })
        Row(stringResource(R.string.annual_cost), officialDpe.num("annual_cost_eur")?.let { stringResource(R.string.unit_eur_year, it.toInt()) })

        /* Les logements diagnostiqués, en lignes COMPACTES (#22) : classe,
         * surface, coût — le détail complet vit dans la fiche PDF ciblée que
         * le petit bouton va chercher (décision opérateur : « less info at
         * first, and then all in PDF »). */
        val logements = (spread as? JsonObject)?.get("logements") as? JsonArray
        if (model != null && logements != null && logements.size >= 2) {
            val context = LocalContext.current
            val scope = rememberCoroutineScope()
            var enCours by remember { mutableStateOf<String?>(null) }
            HorizontalDivider(Modifier.padding(vertical = 6.dp))
            logements.forEach { el ->
                val l = el as? JsonObject ?: return@forEach
                val numero = l.str("numero_dpe") ?: return@forEach
                val surface = l.num("surface_m2")
                val cout = l.num("cout_annuel_eur")
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(22.dp).clip(RoundedCornerShape(5.dp))
                            .background(dpeColor(l.str("classe"))),
                        contentAlignment = Alignment.Center) {
                        Text(l.str("classe") ?: "?", color = Color.White,
                            fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(listOfNotNull(
                            surface?.let { stringResource(R.string.unit_m2_txt, fmtSurface(it)) },
                            cout?.let { stringResource(R.string.unit_eur_year, it.toInt()) })
                        .joinToString(" · "), fontSize = 13.sp)
                    Spacer(Modifier.weight(1f))
                    if (enCours == numero) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        IconButton(onClick = {
                            val id = model.buildingId ?: return@IconButton
                            enCours = numero
                            scope.launch {
                                runCatching {
                                    Api.report(context, id, model.lon, model.lat, dpe = numero)
                                }.onSuccess(onReport)
                                enCours = null
                            }
                        }, enabled = enCours == null, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Filled.Description,
                                contentDescription = stringResource(R.string.report_this_dwelling),
                                tint = Color(0.17f, 0.48f, 0.29f))
                        }
                    }
                }
            }
        }
    }
}

/** 15.6 -> « 15,6 » ; 57.0 -> « 57 » : la surface telle qu'une annonce l'écrit. */
private fun fmtSurface(m2: Double): String =
    if (m2 == m2.toLong().toDouble()) m2.toLong().toString()
    else "%.1f".format(m2).replace(".", ",")

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.Gray)
        content()
    }
}

/**
 * Une valeur absente disparaît : une fiche pleine de tirets paraît vide. Et
 * « INDETERMINE », que la BDNB renvoie tel quel, n'apprend rien à personne.
 */
@Composable
private fun Row(label: String, value: String?) {
    if (value == null || value.trim().uppercase().startsWith("INDETERMINE")) return
    // Écart GARANTI entre l'intitulé et la valeur : avec un simple ressort, une
    // valeur qui passe à la ligne le comprimait à zéro et le texte se collait à
    // son intitulé (« NaturelsInondation, Séisme… »).
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, color = Color.Gray, fontSize = 14.sp)
        Text(value, fontSize = 14.sp, modifier = Modifier.weight(1f),
            textAlign = androidx.compose.ui.text.style.TextAlign.End)
    }
}

/**
 * La commune au sens CIVIL, et le nom qu'elle portait avant (#275).
 *
 * Un acte ancien nomme parfois une commune qui n'existe plus. Et quand rien
 * n'a bougé, le dire — daté et sourcé — vaut aussi la peine.
 *
 * Les réserves de la source sont reprises, jamais résumées : répéter ses
 * chiffres sans ses réserves affirmerait plus qu'elle.
 */
@Composable
private fun CommuneSection(commune: JsonElement?) {
    val nom = commune.str("nom") ?: return
    Section(stringResource(R.string.section_commune)) {
        Row(stringResource(R.string.commune_name),
            commune.str("code")?.let { "$nom ($it)" } ?: nom)
        val encore = (commune.obj("existe_encore") as? JsonPrimitive)?.booleanOrNull ?: true
        // La date de FIN quand la commune a cessé d'exister, et non celle de
        // début : la fiche annonçait « a cessé d'exister le 1ᵉʳ janvier 1870 »
        // en affichant le commencement de la version.
        Row(stringResource(if (encore) R.string.commune_since else R.string.commune_ended),
            commune.str(if (encore) "depuis_fr" else "jusqu_au_fr"))
        val avant = commune.obj("precedent")
        avant.str("nom")?.let { n ->
            Row(stringResource(R.string.commune_before),
                avant.str("jusqu_au_fr")?.let { "$n, jusqu'au $it" } ?: n)
        }
        Row(stringResource(R.string.commune_asof), commune.str("arret_des_donnees_fr"))
        val reserves = commune.strings("limites") +
            ((commune.obj("non_etablis") as? JsonArray)?.mapNotNull { it.str("texte") }
                ?: emptyList())
        if (reserves.isNotEmpty()) {
            Text(reserves.joinToString(" "), fontSize = 11.sp, color = Color.Gray)
        }
    }
}

@Composable
private fun RisksSection(risks: JsonElement?) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val natural = risks.strings("risques_naturels")
    val techno = risks.strings("risques_technologiques")
    if (natural.isEmpty() && techno.isEmpty()) return
    Section(stringResource(R.string.section_risks)) {
        if (natural.isNotEmpty()) Row(stringResource(R.string.risks_natural), natural.joinToString(", ") { humanize(ctx, it) })
        if (techno.isNotEmpty()) Row(stringResource(R.string.risks_techno), techno.joinToString(", ") { humanize(ctx, it) })
        Row(stringResource(R.string.clay_hazard), risks.str("clay_shrink_swell"))
    }
}

/**
 * Les clés de Géorisques arrivent en langage machine
 * (« retraitGonflementArgile ») : personne ne doit lire ça dans une fiche.
 */
private val RISK_NAMES = mapOf(
    "inondation" to R.string.risk_inondation,
    "remonteeNappe" to R.string.risk_remonteeNappe,
    "seisme" to R.string.risk_seisme,
    "mouvementTerrain" to R.string.risk_mouvementTerrain,
    "retraitGonflementArgile" to R.string.risk_retraitGonflementArgile,
    "feuForet" to R.string.risk_feuForet,
    "radon" to R.string.risk_radon,
    "icpe" to R.string.risk_icpe,
    "pollutionSols" to R.string.risk_pollutionSols,
    "nucleaire" to R.string.risk_nucleaire,
    "ruptureBarrage" to R.string.risk_ruptureBarrage,
    "risqueMinier" to R.string.risk_risqueMinier,
    "cavite" to R.string.risk_cavite,
    "avalanche" to R.string.risk_avalanche,
    "canalisationsMatieresDangereuses" to R.string.risk_canalisationsMatieresDangereuses,
)

private fun humanize(ctx: Context, key: String): String = RISK_NAMES[key]?.let(ctx::getString)
    ?: key.replace(Regex("([a-z])([A-Z])"), "$1 $2").replaceFirstChar { it.uppercase() }

@Composable
private fun EnvironmentSection(groundwater: JsonElement?, solar: JsonElement?, water: JsonElement?) {
    val depth = groundwater.num("depth_m")
    val yield_ = solar.num("yield_kwh_per_kwc_y")
    val efficiency = water.num("efficiency_pct")
    if (depth == null && yield_ == null && efficiency == null) return
    Section(stringResource(R.string.section_environment)) {
        Row(stringResource(R.string.groundwater), depth?.let { fmt("%.1f m", it) })
        Row(stringResource(R.string.solar), yield_?.let { stringResource(R.string.unit_solar, it.toInt()) })
        Row(stringResource(R.string.water_efficiency), efficiency?.let { fmt("%.1f %%", it) })
        Row(stringResource(R.string.water_price), water.num("price_eur_m3")?.let { fmt("%.2f €/m³", it) })
    }
}

@Composable
private fun NeighbourhoodSection(taxes: JsonElement?, schools: JsonElement?, prices: JsonElement?) {
    val medians = prices.obj("commune_eur_m2") as? JsonObject ?: JsonObject(emptyMap())
    val nbSchools = (schools as? JsonArray)?.size ?: 0
    val tax = taxes.num("property_tax_built_pct")
    if (medians.isEmpty() && nbSchools == 0 && tax == null) return
    Section(stringResource(R.string.section_area)) {
        medians.keys.sorted().forEach { k ->
            Row(stringResource(R.string.median_price, k.lowercase()),
                (medians[k] as JsonElement?).num("median")?.toInt()?.let { stringResource(R.string.unit_eur_m2, it) })
        }
        Row(stringResource(R.string.property_tax), tax?.let { fmt("%.2f %%", it) })
        Row(stringResource(R.string.waste_tax), taxes.num("waste_tax_pct")?.let { fmt("%.2f %%", it) })
        Row(stringResource(R.string.schools), if (nbSchools > 0) "$nbSchools" else null)
    }
}

/** Format FRANÇAIS : la virgule décimale, pas le point. */
private fun fmt(pattern: String, value: Double): String =
    String.format(java.util.Locale.FRANCE, pattern, value)

private fun JsonElement?.strings(key: String): List<String> =
    (this.obj(key) as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        ?: emptyList()

private fun String.capitalize(): String =
    lowercase().replaceFirstChar { it.uppercase() }
