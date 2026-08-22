package io.confinia.ecobuilding

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.serialization.json.*
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

/**
 * Identifiant d'INSTALLATION, envoyé en en-tête `X-Install-Id`.
 *
 * C'est lui qui porte le quota. Il ne peut pas être remplacé par l'adresse IP :
 * sur réseau mobile, des milliers d'abonnés la partagent, et les fiches
 * offertes d'un utilisateur seraient consommées par de parfaits inconnus.
 *
 * Ce n'est **pas** de l'authentification — désinstaller l'app le supprime.
 * C'est assumé : l'enjeu vaut 0,99 €, et un contrôle plus dur coûterait plus en
 * adhésion qu'il ne rapporterait. Même choix que sur iPhone.
 */
object InstallId {
    private const val PREFS = "ecobuilding"
    private const val KEY = "install_id"
    private var cached: String? = null

    fun get(context: Context): String = cached ?: synchronized(this) {
        val prefs: SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existing = prefs.getString(KEY, null)
        val value = existing ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(KEY, it).apply()
        }
        cached = value
        value
    }
}

/** Un événement du flux NDJSON de l'API. */
sealed interface StreamEvent {
    data class Core(val query: JsonObject, val buildings: JsonArray) : StreamEvent
    data class Block(val name: String, val value: JsonElement) : StreamEvent
    data class Done(val query: JsonObject, val sources: List<String>) : StreamEvent
    data class Failure(val status: Int, val detail: String) : StreamEvent
}

data class Suggestion(
    val label: String, val lon: Double, val lat: Double, val banId: String?,
)

data class Quota(
    val plan: String,
    val reportsUsed: Int,
    val reportsIncluded: Int?,
    val reportsLeft: Int?,
    val units: Int,
    val period: String?,
    val resetsAt: String?,
    val freeAgain: List<String>,
)

/**
 * Client de l'API EcoBuilding — transposition EXACTE du client iPhone.
 *
 * L'app ne calcule rien : toute l'intelligence métier est côté serveur, et les
 * prix eux-mêmes viennent de `/v1/config`. On n'écrit jamais un tarif en dur.
 */
object Api {
    private const val BASE = "https://ecobuilding.confinia.io/api/v1"
    private val json = Json { ignoreUnknownKeys = true }

    private fun open(context: Context, path: String): HttpURLConnection =
        (URL("$BASE/$path").openConnection() as HttpURLConnection).apply {
            setRequestProperty("X-Install-Id", InstallId.get(context))
            connectTimeout = 15_000
            readTimeout = 120_000
        }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    // --- Recherche d'adresse -------------------------------------------------

    suspend fun suggest(context: Context, text: String): List<Suggestion> =
        withIo {
            val conn = open(context, "suggest?q=${enc(text)}")
            val body = conn.inputStream.bufferedReader().use(BufferedReader::readText)
            // La clé est « suggestions ». Côté iPhone, l'avoir lue « results »
            // faisait échouer le décodage à chaque frappe, en silence.
            val arr = json.parseToJsonElement(body).jsonObject["suggestions"]?.jsonArray
                ?: JsonArray(emptyList())
            arr.map { it.jsonObject }.map {
                Suggestion(
                    label = it["label"]?.jsonPrimitive?.content.orEmpty(),
                    lon = it["lon"]?.jsonPrimitive?.double ?: 0.0,
                    lat = it["lat"]?.jsonPrimitive?.double ?: 0.0,
                    banId = it["ban_id"]?.jsonPrimitive?.contentOrNull,
                )
            }
        }

    // --- Fiche bâtiment, AU FIL DE L'EAU -------------------------------------

    /**
     * Neuf sources ouvertes sont interrogées par bâtiment ; attendre la plus
     * lente laissait l'utilisateur devant un écran vide plusieurs secondes
     * (mesuré : 5,7 s, contre 0,6 s pour le bâtiment seul). On affiche donc dès
     * que le bâtiment arrive, puis chaque bloc à son tour.
     */
    fun buildingStream(context: Context, id: String, lon: Double, lat: Double) =
        stream(context, "buildings/$id/stream?lon=$lon&lat=$lat")

    fun lookupStream(context: Context, q: String) =
        stream(context, "lookup/stream?q=${enc(q)}")

    /** Suggestion CHOISIE : on tient déjà l'identifiant BAN et le point. */
    fun lookupStream(context: Context, banId: String, lon: Double, lat: Double) =
        stream(context, "lookup/stream?ban_id=${enc(banId)}&lon=$lon&lat=$lat")

    private fun stream(context: Context, path: String): Flow<StreamEvent> = flow {
        val conn = open(context, path)
        if (conn.responseCode >= 400) {
            emit(StreamEvent.Failure(conn.responseCode, ""))
            return@flow
        }
        conn.inputStream.bufferedReader().useLines { lines ->
            for (line in lines) {
                if (line.isBlank()) continue
                val obj = runCatching { json.parseToJsonElement(line).jsonObject }
                    .getOrNull() ?: continue
                when (obj["type"]?.jsonPrimitive?.contentOrNull) {
                    "core" -> emit(StreamEvent.Core(
                        obj["query"]?.jsonObject ?: JsonObject(emptyMap()),
                        obj["buildings"]?.jsonArray ?: JsonArray(emptyList())))
                    "block" -> obj["name"]?.jsonPrimitive?.contentOrNull?.let {
                        emit(StreamEvent.Block(it, obj["value"] ?: JsonNull))
                    }
                    "done" -> emit(StreamEvent.Done(
                        obj["query"]?.jsonObject ?: JsonObject(emptyMap()),
                        obj["sources"]?.jsonArray?.mapNotNull {
                            it.jsonPrimitive.contentOrNull
                        } ?: emptyList()))
                    "error" -> emit(StreamEvent.Failure(
                        obj["status"]?.jsonPrimitive?.intOrNull ?: 0,
                        obj["detail"]?.jsonPrimitive?.contentOrNull.orEmpty()))
                }
            }
        }
    }.flowOn(Dispatchers.IO)

    // --- Quota ---------------------------------------------------------------

    suspend fun quota(context: Context): Quota = withIo {
        val body = open(context, "quota").inputStream.bufferedReader()
            .use(BufferedReader::readText)
        val o = json.parseToJsonElement(body).jsonObject
        Quota(
            plan = o["plan"]?.jsonPrimitive?.content.orEmpty(),
            reportsUsed = o["reports_used"]?.jsonPrimitive?.intOrNull ?: 0,
            reportsIncluded = o["reports_included"]?.jsonPrimitive?.intOrNull,
            reportsLeft = o["reports_left"]?.jsonPrimitive?.intOrNull,
            units = o["units"]?.jsonPrimitive?.intOrNull ?: 0,
            period = o["period"]?.jsonPrimitive?.contentOrNull,
            resetsAt = o["resets_at"]?.jsonPrimitive?.contentOrNull,
            freeAgain = o["free_again"]?.jsonArray?.mapNotNull {
                it.jsonPrimitive.contentOrNull
            } ?: emptyList(),
        )
    }

    /**
     * Télécharge la fiche PDF DANS l'app, puis renvoie le fichier.
     *
     * Surtout pas un lien confié au navigateur : celui-ci n'envoie pas
     * `X-Install-Id`, le serveur ne reconnaîtrait plus l'appareil et le quota
     * retomberait sur l'adresse IP — partagée par des milliers d'abonnés en
     * réseau mobile. La requête doit partir d'ici.
     */
    suspend fun report(context: Context, id: String, lon: Double?, lat: Double?): java.io.File =
        withIo {
            val query = if (lon != null && lat != null) "?lon=$lon&lat=$lat" else ""
            val conn = open(context, "report/$id.pdf$query")
            if (conn.responseCode >= 400) {
                val detail = conn.errorStream?.bufferedReader()?.use(BufferedReader::readText)
                throw ReportError(conn.responseCode, detail.orEmpty())
            }
            // Le dossier « reports » du cache est déclaré au FileProvider : c'est
            // lui qui autorise un lecteur externe à lire le fichier, sans rendre
            // le reste des données de l'app accessible.
            val dir = java.io.File(context.cacheDir, "reports").apply { mkdirs() }
            val file = java.io.File(dir, "ecobuilding-$id.pdf")
            conn.inputStream.use { input -> file.outputStream().use { input.copyTo(it) } }
            file
        }

    private suspend fun <T> withIo(block: () -> T): T =
        kotlinx.coroutines.withContext(Dispatchers.IO) { block() }
}

/** 402/429 portent un message serveur destiné à l'utilisateur : on le garde. */
class ReportError(val status: Int, val detail: String) : Exception(detail)

