# EcoBuilding — applications mobiles

Applications iOS et Android d'EcoBuilding : carte 3D des bâtiments
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

## Android

```sh
brew install openjdk@21
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
cd android && ./gradlew :app:assembleDebug
$ANDROID_HOME/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`local.properties` (chemin du SDK) est **local** et n'est pas versionné ;
`assembleDebug` le crée au besoin, ou écrivez-y `sdk.dir=$ANDROID_HOME`.

### Émulateur

```sh
sdkmanager --sdk_root="$ANDROID_HOME" --install emulator \
  "system-images;android-35;google_apis;arm64-v8a" "cmdline-tools;latest"
$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager create avd -n eco35 \
  -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_6
$ANDROID_HOME/emulator/emulator -avd eco35 -gpu swiftshader_indirect -no-audio &
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb emu geo fix 1.319551 43.593142        # position simulée
```

Utilisez l'`avdmanager` **du SDK**, pas celui de Homebrew : ce dernier ne
retrouve pas les images installées.

L'émulateur mérite le détour : les défauts les plus coûteux — un `JsonNull` qui
fait tomber l'app, une expression de couleur mal résolue, un bouton hors écran —
ne se voient pas à la compilation.

L'application vise Android 8.0 (API 26) et au-delà : cela couvre la quasi-
totalité du parc encore en service, sans traîner de code de compatibilité pour
des versions que plus personne n'utilise.

Elle ne dépend PAS des services Google Play — position lue via `LocationManager`,
cartes par MapLibre. Elle tourne donc telle quelle sur les appareils vendus sans
services Google, et aucune dépendance propriétaire ne s'impose aux utilisateurs.

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

### Simulateur

```sh
xcodebuild -downloadPlatform iOS          # ~8,5 Go, une seule fois
xcrun simctl boot "iPhone 17"
xcodebuild -project EcoBuilding.xcodeproj -scheme EcoBuilding \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath dd build
xcrun simctl install "iPhone 17" dd/Build/Products/Debug-iphonesimulator/EcoBuilding.app
xcrun simctl launch "iPhone 17" io.confinia.ecobuilding
xcrun simctl location "iPhone 17" set 43.593142,1.319551   # position simulée
xcrun simctl io "iPhone 17" screenshot vue.png
```

L'identifiant est `io.confinia.ecobuilding`, **en minuscules** : `simctl` refuse
d'ouvrir l'app si l'on se fie à la casse du nom de cible.

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
