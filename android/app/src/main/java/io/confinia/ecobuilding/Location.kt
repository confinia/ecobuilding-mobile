package io.confinia.ecobuilding

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.core.content.ContextCompat
import org.maplibre.android.geometry.LatLng

/**
 * Un seul point GPS, pour centrer la carte au lancement.
 *
 * Volontairement sans Google Play services : l'app doit tourner sur les
 * téléphones sans services Google, et une dépendance propriétaire pour lire une
 * latitude serait payée par tous les utilisateurs.
 *
 * La position ne quitte JAMAIS l'appareil : elle sert à positionner la caméra,
 * et la requête envoyée au serveur porte le bâtiment choisi, pas l'utilisateur.
 */
object UserLocation {

    fun granted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Rappelle avec la position dès qu'elle est connue. Le dernier point connu
     * est renvoyé immédiatement s'il existe : attendre un vrai relevé peut
     * prendre trente secondes en intérieur, et la carte resterait sur la France
     * entière pendant ce temps.
     */
    @SuppressLint("MissingPermission")
    fun once(context: Context, onFix: (LatLng) -> Unit) {
        if (!granted(context)) return
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
        val providers = manager.getProviders(true)

        providers.asSequence()
            .mapNotNull { runCatching { manager.getLastKnownLocation(it) }.getOrNull() }
            .maxByOrNull { it.time }
            ?.let { onFix(LatLng(it.latitude, it.longitude)); return }

        val provider = when {
            LocationManager.FUSED_PROVIDER in providers -> LocationManager.FUSED_PROVIDER
            LocationManager.GPS_PROVIDER in providers -> LocationManager.GPS_PROVIDER
            LocationManager.NETWORK_PROVIDER in providers -> LocationManager.NETWORK_PROVIDER
            else -> return
        }
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                manager.removeUpdates(this)
                onFix(LatLng(location.latitude, location.longitude))
            }
            @Deprecated("API < 30")
            override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
            override fun onProviderDisabled(provider: String) {}
            override fun onProviderEnabled(provider: String) {}
        }
        runCatching {
            manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
        }
    }
}
