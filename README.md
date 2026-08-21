# EcoBuilding — applications mobiles

Applications iOS (et à venir Android) d'EcoBuilding : carte 3D des bâtiments
français colorés par classe énergétique, fiche détaillée, fiche PDF partageable.

**Dépôt privé, et il doit le rester.** Le produit web est destiné à l'open
source ; le mobile est la partie commerciale. Les deux communiquent par l'API
publique `/v1`, dont le contrat est vérifié à chaque déploiement côté serveur.

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
`~/.appstoreconnect/private_keys/`.
