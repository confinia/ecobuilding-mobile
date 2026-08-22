package io.confinia.ecobuilding

import android.annotation.SuppressLint
import android.graphics.Color
import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression.*
import org.maplibre.android.style.layers.FillExtrusionLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.layers.RasterLayer
import org.maplibre.android.style.sources.RasterSource
import org.maplibre.android.style.sources.TileSet
import org.maplibre.android.style.sources.VectorSource
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Carte 3D des bâtiments, colorés par classe DPE — iso avec l'iPhone.
 *
 * Les tuiles viennent de NOTRE cache (`/v1/tiles`), jamais d'api.bdnb.io en
 * direct : ce service est anonyme et plafonné par IP (120 req/min,
 * 10 000/mois), et MapLibre redemande la même tuile une fois par identifiant
 * sur-zoomé — mesuré 10 à 17 fois par affichage. En direct, la carte se vidait
 * silencieusement au bout de quelques minutes d'usage.
 *
 * BDNB ne publie que le **z14** : demander un autre niveau ne ramène rien.
 */
object MapIds {
    const val SOURCE = "bdnb"
    const val LAYER = "bdnb-dpe-3d"
    const val SELECTED = "bdnb-selected"
    const val OUTLINE = "bdnb-selected-outline"
    const val AERIAL = "ign-ortho"
    const val PIN = "pin"
    const val TILES = "https://ecobuilding.confinia.io/api/v1/tiles/batiment_groupe/{z}/{x}/{y}.pbf"
    /** Photo aérienne IGN — Licence Ouverte, sans clé ni compte. */
    const val ORTHO = "https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0" +
        "&LAYER=ORTHOIMAGERY.ORTHOPHOTOS&STYLE=normal&TILEMATRIXSET=PM" +
        "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/jpeg"

    const val OPEN_ZOOM = 10.0
    const val WORK_ZOOM = 17.0
    /** Le relief EST le produit : à plat, rien ne distingue une passoire de
     *  quatre étages d'une maison de plain-pied. */
    const val PITCH = 30.0
}

private val DPE_COLORS = arrayOf(
    "A" to Color.rgb(0, 143, 54), "B" to Color.rgb(82, 177, 83),
    "C" to Color.rgb(165, 204, 116), "D" to Color.rgb(244, 231, 15),
    "E" to Color.rgb(240, 180, 15), "F" to Color.rgb(235, 130, 53),
    "G" to Color.rgb(215, 34, 31),
)
private val DPE_DARK = arrayOf(
    "A" to Color.rgb(0, 79, 30), "B" to Color.rgb(41, 102, 43),
    "C" to Color.rgb(92, 128, 51), "D" to Color.rgb(153, 143, 8),
    "E" to Color.rgb(148, 110, 8), "F" to Color.rgb(143, 77, 26),
    "G" to Color.rgb(125, 15, 15),
)

private fun dpeMatch(palette: Array<Pair<String, Int>>, fallback: Int) =
    match(get("classe_bilan_dpe"),
        literal(fallback),
        *palette.flatMap { (k, c) -> listOf(literal(k), literal(c)) }.toTypedArray())

@SuppressLint("ClickableViewAccessibility")
@Composable
fun BuildingMap(
    modifier: Modifier = Modifier,
    aerial: Boolean,
    showUser: Boolean,
    pin: LatLng?,
    highlighted: String?,
    focus: LatLng?,
    onArmed: (String?) -> Unit,
    onSelect: (String, LatLng) -> Unit,
) {
    val state = remember { MapState() }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current

    // MapLibre est une vue Android : sans ces appels, le rendu ne démarre pas
    // toujours, et le contexte GL n'est jamais rendu au système en quittant.
    DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            val view = state.view ?: return@LifecycleEventObserver
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_START -> view.onStart()
                androidx.lifecycle.Lifecycle.Event.ON_RESUME -> view.onResume()
                androidx.lifecycle.Lifecycle.Event.ON_PAUSE -> view.onPause()
                androidx.lifecycle.Lifecycle.Event.ON_STOP -> view.onStop()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            state.view?.onDestroy()
            state.view = null
            state.map = null
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            MapLibre.getInstance(ctx)
            MapView(ctx).apply {
                state.view = this
                onCreate(null)
                onStart()
                onResume()
                getMapAsync { map ->
                    state.map = map
                    map.setStyle(Style.Builder().fromUri("https://tiles.openfreemap.org/styles/liberty")) { style ->
                        installLayers(ctx, style)
                        state.applyHighlight(highlighted)
                    }
                    map.cameraPosition = CameraPosition.Builder()
                        .target(LatLng(46.6, 2.5)).zoom(4.5).build()
                    map.addOnMapClickListener { point ->
                        state.handleTap(map, point, onArmed, onSelect)
                        true
                    }
                }
            }
        },
        update = { view ->
            val map = state.map ?: return@AndroidView
            map.style?.getLayer(MapIds.AERIAL)?.setProperties(
                visibility(if (aerial) org.maplibre.android.style.layers.Property.VISIBLE
                           else org.maplibre.android.style.layers.Property.NONE))
            // Sur la photo, les volumes cachent précisément le toit qu'on vient
            // regarder : on les retire, le contour suffit à désigner.
            val volumes = if (aerial) org.maplibre.android.style.layers.Property.NONE
                          else org.maplibre.android.style.layers.Property.VISIBLE
            map.style?.getLayer(MapIds.LAYER)?.setProperties(visibility(volumes))
            map.style?.getLayer(MapIds.SELECTED)?.setProperties(visibility(volumes))

            // La permission peut être accordée APRÈS le premier affichage :
            // on réessaie tant que le point bleu n'est pas posé.
            if (showUser && !state.userDotOn) {
                map.style?.let { style -> state.enableUserDot(view.context, map, style) }
            }
            if (pin != state.lastPin) {
                state.lastPin = pin
                state.movePin(map, pin)
            }
            if (state.lastHighlighted != highlighted) {
                state.lastHighlighted = highlighted
                state.applyHighlight(highlighted)
            }
            if (focus != null && focus != state.lastFocus) {
                state.lastFocus = focus
                state.flyTo(map, focus)
            }
        },
    )
}

/** État vivant de la carte, hors recomposition. */
private class MapState {
    var map: MapLibreMap? = null
    var view: MapView? = null
    var lastHighlighted: String? = null
    var lastFocus: LatLng? = null
    var lastPin: LatLng? = null
    var userDotOn = false
    /** Bâtiment désigné par le premier appui, en attente de confirmation. */
    private var armed: String? = null

    /** Le point bleu : sans lui, on ne sait pas d'où l'on regarde. */
    @SuppressLint("MissingPermission")
    fun enableUserDot(context: android.content.Context, map: MapLibreMap, style: Style) {
        if (!UserLocation.granted(context)) return
        runCatching {
            map.locationComponent.apply {
                activateLocationComponent(
                    org.maplibre.android.location.LocationComponentActivationOptions
                        .builder(context, style).useDefaultLocationEngine(true).build())
                isLocationComponentEnabled = true
                renderMode = org.maplibre.android.location.modes.RenderMode.NORMAL
                // La caméra reste LIBRE : un suivi automatique ramènerait la vue
                // sur l'utilisateur pendant qu'il examine un autre quartier.
                cameraMode = org.maplibre.android.location.modes.CameraMode.NONE
            }
            userDotOn = true
        }
    }

    /** Déplace l'épingle, ou la retire quand plus rien n'est visé. */
    fun movePin(map: MapLibreMap, point: LatLng?) {
        val source = map.style?.getSourceAs<org.maplibre.android.style.sources.GeoJsonSource>(
            MapIds.PIN + "-src") ?: return
        if (point == null) {
            source.setGeoJson(org.maplibre.geojson.FeatureCollection.fromFeatures(emptyList()))
        } else {
            source.setGeoJson(org.maplibre.geojson.Feature.fromGeometry(
                org.maplibre.geojson.Point.fromLngLat(point.longitude, point.latitude)))
        }
    }

    fun applyHighlight(id: String?) {
        val f = eq(get("batiment_groupe_id"), literal(id ?: ""))
        map?.style?.getLayerAs<FillExtrusionLayer>(MapIds.SELECTED)?.setFilter(f)
        map?.style?.getLayerAs<LineLayer>(MapIds.OUTLINE)?.setFilter(f)
    }

    /**
     * Vol en DEUX temps : prise de champ, puis plongée. Un déplacement à zoom
     * constant traverse le pays au ras des toits — illisible, et on ne comprend
     * pas où l'on atterrit.
     */
    fun flyTo(map: MapLibreMap, target: LatLng) {
        val dive = CameraUpdateFactory.newCameraPosition(
            CameraPosition.Builder().target(target)
                .zoom(MapIds.WORK_ZOOM).tilt(MapIds.PITCH).build())
        // Enchaîné par rappel, et non par minuterie : une minuterie continue de
        // courir si l'utilisateur relance une recherche entre-temps, et la
        // caméra repart vers l'adresse précédente.
        map.animateCamera(
            CameraUpdateFactory.newCameraPosition(
                CameraPosition.Builder().target(target).zoom(MapIds.OPEN_ZOOM).tilt(0.0).build()),
            1200,
            object : MapLibreMap.CancelableCallback {
                override fun onFinish() { map.animateCamera(dive, 1400) }
                override fun onCancel() {}
            })
    }

    /**
     * Sélection en DEUX temps, et visée sur le VOLUME.
     *
     * MapLibre teste la collision sur l'emprise au SOL : incliné, le toit qu'on
     * voit est décalé vers le haut de l'écran, et viser le bâtiment qu'on
     * regarde ne sélectionnait rien — ou désignait le voisin de derrière. On
     * cherche donc aussi sous le point touché.
     */
    fun handleTap(map: MapLibreMap, point: LatLng,
                  onArmed: (String?) -> Unit, onSelect: (String, LatLng) -> Unit) {
        val screen = map.projection.toScreenLocation(point)
        val id = pick(map, screen)
        if (id == null) {
            armed = null
            applyHighlight(null)
            onArmed(null)
            return
        }
        applyHighlight(id)
        if (armed == id) {
            armed = null
            onArmed(null)
            onSelect(id, point)
        } else {
            armed = id
            onArmed(id)
        }
    }

    private fun pick(map: MapLibreMap, screen: PointF): String? {
        map.queryRenderedFeatures(screen, MapIds.LAYER).firstOrNull()
            ?.getStringProperty("batiment_groupe_id")?.let { return it }
        if (map.cameraPosition.tilt < 5) return null

        // Bande vers le bas : là se trouvent les emprises des bâtiments dont on
        // voit le toit plus haut.
        val strip = RectF(screen.x - 30f, screen.y, screen.x + 30f, screen.y + 200f)
        val candidates = map.queryRenderedFeatures(strip, MapIds.LAYER)
        if (candidates.isEmpty()) return null
        val mpp = map.projection.getMetersPerPixelAtLatitude(map.cameraPosition.target!!.latitude)
        val lift = sin(Math.toRadians(map.cameraPosition.tilt)) / mpp.coerceAtLeast(1e-4)
        return candidates.minByOrNull { f ->
            val h = if (f.hasProperty("hauteur_mean")) f.getNumberProperty("hauteur_mean").toDouble() else 6.0
            val g = f.geometry()?.let { map.projection.toScreenLocation(centroid(it)) } ?: screen
            hypot((g.x - screen.x).toDouble(), (g.y - h * lift - screen.y).toDouble())
        }?.getStringProperty("batiment_groupe_id")
    }

    private fun centroid(geom: org.maplibre.geojson.Geometry): LatLng {
        val poly = geom as? org.maplibre.geojson.Polygon
            ?: (geom as? org.maplibre.geojson.MultiPolygon)?.polygons()?.firstOrNull()
        val ring = poly?.coordinates()?.firstOrNull() ?: return LatLng(0.0, 0.0)
        return LatLng(ring.sumOf { it.latitude() } / ring.size,
                      ring.sumOf { it.longitude() } / ring.size)
    }
}

private fun installLayers(context: android.content.Context, style: Style) {
    // Le fond porte ses propres bâtiments OSM, qui ne s'alignent pas sur les
    // emprises BDNB : deux volumes superposés et décalés.
    style.layers.filter { it.id.contains("building", ignoreCase = true) }
        .forEach { style.removeLayer(it) }

    // Photo aérienne, AU-DESSUS du plan : insérée dessous, un fond opaque la
    // masquerait et le bouton paraîtrait mort.
    style.addSource(RasterSource(MapIds.AERIAL + "-src",
        TileSet("2.2.0", MapIds.ORTHO), 256))
    style.addLayer(RasterLayer(MapIds.AERIAL, MapIds.AERIAL + "-src").withProperties(
        visibility(org.maplibre.android.style.layers.Property.NONE)))

    style.addSource(VectorSource(MapIds.SOURCE, TileSet("2.2.0", MapIds.TILES).apply {
        minZoom = 14f
        maxZoom = 14f
    }))

    val height = coalesce(get("hauteur_mean"), literal(6))
    style.addLayer(FillExtrusionLayer(MapIds.LAYER, MapIds.SOURCE).apply {
        sourceLayer = "sql_statement"
        minZoom = 14f
        withProperties(
            fillExtrusionColor(dpeMatch(DPE_COLORS, Color.rgb(213, 205, 192))),
            fillExtrusionHeight(height),
            // Opacité CONSTANTE : par entité, MapLibre invalide la propriété en
            // silence — la leçon a coûté cher côté web.
            fillExtrusionOpacity(0.9f))
    })

    // Assombrir la PROPRE couleur du bâtiment plutôt que tout peindre en vert :
    // le vert uniforme effaçait la classe DPE, l'information même qu'on cherche.
    style.addLayer(FillExtrusionLayer(MapIds.SELECTED, MapIds.SOURCE).apply {
        sourceLayer = "sql_statement"
        minZoom = 14f
        setFilter(eq(get("batiment_groupe_id"), literal("")))
        withProperties(
            fillExtrusionColor(dpeMatch(DPE_DARK, Color.rgb(107, 99, 89))),
            fillExtrusionHeight(height),
            fillExtrusionOpacity(1.0f))
    })

    // Épingle : au-dessus de tout, sans jamais disparaître pour cause de
    // chevauchement — c'est elle qui répond à « lequel ai-je sélectionné ? ».
    pinBitmap(context)?.let { style.addImage(MapIds.PIN, it) }
    style.addSource(org.maplibre.android.style.sources.GeoJsonSource(MapIds.PIN + "-src"))
    style.addLayer(org.maplibre.android.style.layers.SymbolLayer(
        MapIds.PIN, MapIds.PIN + "-src").withProperties(
            iconImage(MapIds.PIN),
            iconAnchor(org.maplibre.android.style.layers.Property.ICON_ANCHOR_BOTTOM),
            iconAllowOverlap(true), iconIgnorePlacement(true)))

    // Contour au sol : visible dans les deux modes, et il ne masque rien.
    style.addLayer(LineLayer(MapIds.OUTLINE, MapIds.SOURCE).apply {
        sourceLayer = "sql_statement"
        minZoom = 14f
        setFilter(eq(get("batiment_groupe_id"), literal("")))
        withProperties(lineColor(Color.rgb(0, 122, 255)), lineWidth(3f), lineOpacity(0.95f))
    })
}

/** Le vecteur devient une image : MapLibre ne prend que des bitmaps. */
private fun pinBitmap(context: android.content.Context): android.graphics.Bitmap? {
    val drawable = androidx.core.content.ContextCompat
        .getDrawable(context, R.drawable.ic_pin) ?: return null
    val density = context.resources.displayMetrics.density
    val width = (24 * density).toInt().coerceAtLeast(1)
    val height = (32 * density).toInt().coerceAtLeast(1)
    val bitmap = android.graphics.Bitmap.createBitmap(
        width, height, android.graphics.Bitmap.Config.ARGB_8888)
    drawable.setBounds(0, 0, width, height)
    drawable.draw(android.graphics.Canvas(bitmap))
    return bitmap
}
