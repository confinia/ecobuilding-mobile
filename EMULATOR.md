# Émulateurs Android et iPhone

Comment installer, lancer et piloter les deux appareils virtuels depuis un
Mac Apple Silicon, en ligne de commande.

Ils méritent le détour : les défauts les plus coûteux de ce produit — une
donnée nulle qui fait tomber l'app, une expression de couleur mal résolue, un
bouton hors écran, un bâtiment voisin sélectionné à la place du bon — **ne se
voient pas à la compilation**. Ils se voient en jouant le parcours.

---

## Android

### Installer

```sh
brew install openjdk@21 android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk

sdkmanager --sdk_root="$ANDROID_HOME" --install \
  "platform-tools" "platforms;android-35" "build-tools;35.0.0" \
  "emulator" "system-images;android-35;google_apis;arm64-v8a" "cmdline-tools;latest"
```

Comptez environ **4 Go** pour l'image système, et un téléchargement qui peut
traîner.

> Utilisez l'`avdmanager` **du SDK** (`$ANDROID_HOME/cmdline-tools/latest/bin/`)
> et non celui de Homebrew : ce dernier ne retrouve pas les images installées et
> répond « Package path is not valid », quelles que soient les variables
> d'environnement.

### Créer l'appareil et le lancer

```sh
$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager create avd -n eco35 \
  -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_6

$ANDROID_HOME/emulator/emulator -avd eco35 -gpu swiftshader_indirect -no-audio &
adb wait-for-device
```

`swiftshader_indirect` force le rendu logiciel : plus lent, mais il évite les
plantages de pilote graphique observés avec l'accélération matérielle.

### Installer et lancer l'app

```sh
cd android && ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n io.confinia.ecobuilding/.MainActivity
```

### Piloter

```sh
adb emu geo fix 4.335445 46.643645        # longitude PUIS latitude
adb exec-out screencap -p > vue.png
adb shell input tap 540 1200
adb shell input text "12" ; adb shell input keyevent 62 ; adb shell input text "rue"
adb shell uiautomator dump /sdcard/u.xml && adb shell cat /sdcard/u.xml
adb logcat -d | grep -E "FATAL|AndroidRuntime"
```

Deux pièges :

- `adb emu geo fix` attend **longitude puis latitude**, l'inverse de l'usage
  courant, et n'envoie qu'un point isolé. Si l'application vient de démarrer et
  n'écoute pas encore, le point est perdu : rejouez la commande.
- `adb shell input text` ne passe pas les espaces. Découpez les mots et
  intercalez `adb shell input keyevent 62`.

`uiautomator dump` est le moyen le plus fiable de savoir ce qui est affiché :
il donne les textes **et** leurs coordonnées, donc où toucher.

---

## iPhone

### Installer

```sh
xcodebuild -downloadPlatform iOS      # ~8,5 Go, une seule fois
xcrun simctl list runtimes            # doit lister iOS 26.5
```

C'est l'équivalent en ligne de commande de *Xcode > Settings > Components*. Sans
cette plateforme, `xcodebuild` répond « Found no destinations » et refuse même
de compiler pour un appareil réel.

### Compiler, installer, lancer

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ios && xcodegen
xcrun simctl boot "iPhone 17" ; open -a Simulator

xcodebuild -project EcoBuilding.xcodeproj -scheme EcoBuilding \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath dd build

xcrun simctl install "iPhone 17" dd/Build/Products/Debug-iphonesimulator/EcoBuilding.app
xcrun simctl launch "iPhone 17" io.confinia.ecobuilding
```

L'identifiant est `io.confinia.ecobuilding`, **en minuscules** : `simctl` refuse
d'ouvrir l'app si l'on se fie à la casse du nom de cible.

### Piloter

```sh
xcrun simctl location "iPhone 17" set 46.643645,4.335445   # latitude PUIS longitude
xcrun simctl privacy "iPhone 17" grant location-always io.confinia.ecobuilding
xcrun simctl io "iPhone 17" screenshot vue.png
```

Notez l'ordre inverse de celui d'Android.

`simctl` sait lancer, poser une position, capturer, accorder une permission —
mais il **ne sait pas toucher l'écran**. Pour rejouer un parcours, il faut la
cible XCUITest :

```sh
xcodebuild test -project EcoBuilding.xcodeproj -scheme EcoBuilding \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Les scénarios vivent dans `ios/EcoBuilding/UITests/`. Ils suivent le même ordre
que le pilotage Android, pour que les captures se comparent écran par écran.

### Clavier français

Le simulateur démarre en anglais, donc en QWERTY :

```sh
xcrun simctl spawn booted defaults write "Apple Global Domain" AppleLanguages -array fr-FR
xcrun simctl spawn booted defaults write "Apple Global Domain" AppleLocale -string fr_FR
xcrun simctl spawn booted defaults write "Apple Global Domain" AppleKeyboards \
  -array "fr_FR@sw=AZERTY;hw=Automatic" "emoji@sw=Emoji"
xcrun simctl shutdown booted && xcrun simctl boot "iPhone 17"
```

Le redémarrage est nécessaire : SpringBoard ne relit ces réglages qu'au
démarrage.

---

## Adresses d'essai

| Adresse | Coordonnées | Intérêt |
|---|---|---|
| 12 rue de la Licorne, 31170 Tournefeuille | `43.593142, 1.319551` | pavillons, DPE variés |
| 16 impasse Jean Jaurès, 71230 Saint-Vallier | `46.643645, 4.335445` | plain-pied, **sans DPE publié** |
| 12 rue Lecourbe, 75015 Paris | `48.843, 2.310` | immeuble, 7 niveaux, risques multiples |

Saint-Vallier est le cas le plus utile : un bâtiment ordinaire dont plusieurs
sources ne renvoient rien. C'est exactement celui qui faisait tomber la version
Android.
