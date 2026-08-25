# Textes de la fiche App Store

Ce que lit un acheteur avant d'installer. C'est le premier contact commercial
du produit — il mérite le même suivi que le code.

Ces fichiers ont été **rapatriés depuis App Store Connect**, ils ne sont pas une
copie de mémoire : ils reflètent ce qui est réellement publié.

```
store/fr-FR/     description, mots-clés, texte promotionnel, sous-titre
store/en-GB/     idem
```

## Limites d'Apple, à respecter avant tout envoi

| Champ | Limite |
|---|---|
| `subtitle.txt` | 30 caractères |
| `keywords.txt` | 100 caractères, **espaces compris** — séparer par des virgules SANS espace |
| `promotional.txt` | 170 caractères — modifiable sans nouvelle soumission |
| `description.txt` | 4 000 caractères |

Les mots-clés avec espaces après les virgules faisaient 102 caractères et
étaient refusés ; sans espaces, 92. Apple sépare sur les virgules, les espaces
ne servent qu'à la lecture humaine.

## Parti pris de traduction

Les termes administratifs **français sont conservés**, avec une glose anglaise :
« Energy rating (DPE) », « Property tax (taxe foncière) ». Un DPE n'est pas un
EPC britannique — méthode de calcul, échelle et portée juridique diffèrent — et
la taxe foncière n'est pas la council tax. Le lecteur apprend le mot qu'il verra
sur l'acte notarié.

La description anglaise le dit explicitement, pour que ce choix ne passe pas
pour une traduction bâclée.

## Captures

Engendrées depuis l'app réelle, jamais dessinées :

```sh
cd ios
xcodebuild test -scheme EcoBuilding \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:EcoBuildingUITests/StoreShots \
  -testLanguage en -testRegion en_GB \
  -resultBundlePath /tmp/shots.xcresult
```

Sans `-testLanguage`, le scénario capture en français **en affichant
TEST SUCCEEDED** : `xcodebuild` ne transmet pas les variables d'environnement au
processus de test. Le scénario constate donc la langue sur une chaîne réellement
traduite au lieu de la supposer.

Puis `python3 store/upload-screenshots.py <dossier>` — le dossier est un
argument, précisément parce qu'un `sed` raté avait envoyé les captures
françaises sur la fiche anglaise.
