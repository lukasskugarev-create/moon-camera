# 🌙 Moon Camera - Flutter App

Aplikácia na fotografovanie mesiaca s automatickým nájdením polohy.

## Funkcie
- 📍 GPS geolokácia → výpočet polohy mesiaca (azimut, výška, vzdialenosť)
- 🔵 Keď je mesiac v zábere → obkrúženie kruhom s pulzovaním
- 🧭 Keď mesiac nie je v zábere → šípka v smere mesiaca
- 🎯 Auto-focus + auto-expozícia nasmerovaná na mesiac
- 📸 Capture + preview fotky

## Inštalácia

### Požiadavky
- Flutter SDK 3.0+
- Android Studio alebo VS Code
- Android telefón (alebo iPhone cez Mac)

### Kroky

```bash
# 1. Stiahni Flutter
# https://flutter.dev/docs/get-started/install/windows

# 2. Prejdi do priečinka projektu
cd moon_camera

# 3. Nainštaluj závislosti
flutter pub get

# 4. Pripoj telefón cez USB (zapni Developer Mode + USB debugging)

# 5. Spusti appku
flutter run
```

## Štruktúra projektu

```
lib/
  main.dart           - vstupný bod appky
  camera_screen.dart  - hlavná obrazovka s kamerou a overlayom
  moon_calculator.dart - astronomické výpočty polohy mesiaca
```

## Ako to funguje

### Výpočet polohy mesiaca
Používa astronomické vzorce (Jean Meeus - Astronomical Algorithms):
1. GPS súradnice → aktuálny čas → Julian Date
2. Orbitálne elementy mesiaca → ekliptické súradnice
3. Konverzia na horizontálne súradnice (azimut + výška)

### Overlay na obrazovke
- Porovnáva azimut mesiaca s orientáciou telefónu
- Ak je mesiac v zornom poli (~60° H × 45° V) → kruh
- Inak → šípka ukazuje smer

## Poznámky
- Kompas nie je implementovaný (potrebuje `flutter_compass` plugin)
- Pre plnú presnosť pridaj: `flutter pub add flutter_compass`
- Mesiac je najkrajší pri Full Moon a nízko nad horizontom (< 30°)

## Tipy na fotografovanie mesiaca 📸
- Použi statív alebo opri telefón
- Fotografuj keď mesiac vychádza/zapadá (krásna farba)
- Vymaž expozíciu ručne ak je mesiac presvietený
