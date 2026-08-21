# EcoBuilding — applications mobiles

Applications iOS (et à venir Android) d'EcoBuilding : carte 3D des bâtiments
français colorés par classe énergétique, fiche détaillée, fiche PDF partageable.

**Sous licence AGPL-3.0.** Ce dépôt est séparé de
[confinia/ecobuilding](https://github.com/confinia/ecobuilding) (le produit web
et l'API) parce qu'une application mobile a son propre cycle : compilations
signées, magasins, versions installées qui survivent des mois à leur serveur.
Les deux communiquent par l'API publique `/v1`, dont le contrat est vérifié à
chaque déploiement côté serveur.

La stratégie commerciale et la tarification vivent à part, dans un dépôt privé :
ce qui est ouvert, c'est le logiciel, pas le plan d'affaires.

## Démarrer

```sh
brew install xcodegen
cd ios && xcodegen && open EcoBuilding.xcodeproj
```

Le `.xcodeproj` est **généré** depuis `ios/project.yml` et n'est pas versionné :
Xcode le réécrit sans cesse et ses conflits sont ingérables.

## Compiler et installer sans Xcode

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ios && xcodegen
xcodebuild -project EcoBuilding.xcodeproj -scheme EcoBuilding -configuration Release \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=38WRV3R7D5 \
  -allowProvisioningUpdates build
ios-deploy --bundle <chemin>/EcoBuilding.app        # sans fil ou par câble
```

**Compiler en Release**, pas en Debug : la configuration Debug embarque des
bibliothèques de débogage qui empêchent l'app de démarrer seule depuis l'écran
d'accueil.

## Distribution

TestFlight, pas l'App Store : la publication européenne exige le statut de
commerçant, donc la publication des coordonnées personnelles tant qu'il n'y a
pas de société. Voir `IPHONE.md` dans le dépôt principal pour le suivi du
passage au payant.

Clés de signature et clés App Store Connect : **jamais dans ce dépôt** —
`~/.appstoreconnect/private_keys/`. Les identifiants Apple non secrets
(équipe, identifiant de lot, clés d'API) sont dans `APPLE.local.md`, exclu du
dépôt.

## Licence

[GNU AGPL-3.0](LICENSE). Toute personne qui exécute une version modifiée de ce
logiciel accessible par le réseau doit en publier les sources.
