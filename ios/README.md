# EcoBuilding iOS — V1

## Ouvrir le projet

```sh
brew install xcodegen        # une seule fois
cd mobile/ios && xcodegen && open EcoBuilding.xcodeproj
```

Le `.xcodeproj` est **généré** depuis `project.yml` et n'est pas versionné :
Xcode le réécrit sans cesse, ses diffs sont illisibles et ses conflits
ingérables. La vérité tient dans `project.yml`.

## Ce que fait la V1

Carte 3D des bâtiments colorés par DPE, recherche d'adresse, fiche qui se
remplit au fil de l'eau, et fiche PDF (payante au-delà des 3 offertes).
Toute l'intelligence est côté serveur : l'app est un client de l'API `/v1` et
n'écrit **aucun prix en dur** — ils viennent de `/v1/config`.

## Points structurants

- **Tuiles** : `/v1/tiles`, jamais api.bdnb.io en direct (quota par IP, carte
  qui se vide en silence). BDNB ne publie que le z14.
- **Quota** : en-tête `X-Install-Id` (voir `InstallID.swift`), pas l'IP — sur
  réseau mobile, des milliers d'abonnés partagent une adresse.
- **Flux** : `/v1/lookup/stream` et `/v1/buildings/{id}/stream` émettent le
  bâtiment d'abord, puis une source à la fois.

## Sur appareil

Compte gratuit : installation possible seulement sur un iPhone **branché au
Mac**, profil valable 7 jours. Pour faire tester à distance (agents
immobiliers), il faut TestFlight, donc le compte à 99 €/an — voir MOBILE.md §6.1.
