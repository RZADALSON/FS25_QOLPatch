# QOL Patch – Farming Simulator 25

Kilka modów w jednym, bezpieczny dla istniejących zapisów i działający w multiplayerze.
*Several quality-of-life mods in one, safe for existing savegames, multiplayer-ready (English below).*

## Funkcje

1. **IBC olej napędowy 1000 l** – zbiornik paliwa na palecie (sklep: IBC / Zbiorniki diesla). Przywieź go na farmę i tankuj maszyny stojące obok. Cena = pojemnik + 1000 l po aktualnej cenie diesla.
   **Dynamiczny rynek paliw** – ceny diesla, AdBlue i metanu zmieniają się (powrót do średniej, sezony, rzadkie kryzysy) względem ceny gry i trudności ekonomicznej.
2. **Finansowanie pojazdów** – menu (ESC) › Finansowanie pojazdów. Pojazd z leasingu zamieniasz na kredyt ratalny (6–84 miesiące, wpłata 0–60%, suwaki, zdjęcie maszyny); zapłacony leasing jest odliczany. Zaległości = opłaty i odsetki karne, po 3 niezapłaconych ratach bank zabiera pojazd, po spłacie pojazd jest Twój.
3. **Fabryki bez kupowania** – „Korzystaj bez kupowania”: płacisz tylko opłatę od wartości przerobionych towarów (po ~10 latach typowego używania zakup byłby tańszy). Lista Twoich fabryk i pokazywanie na mapie.
4. **Długi sen** – w łóżku: 1–12 miesięcy, z prognozą (braki, plony gotowe/gnijące, prawdopodobny zarobek i strata, rekomendacja).
5. **Budowa** – darmowe malowanie i kształtowanie terenu; **Ctrl+Z / Ctrl+Y** cofa i ponawia postawienie lub sprzedaż obiektu ze 100% zwrotem; zakładka **„Farby i oznakowanie”**: pasy parkingowe i oznaczenia drogowe w 4 kolorach, dopasowane do terenu, rozmiar **PgUp/PgDn** (1–10 m).
6. **Pomocnik do zleceń** – w menu Zlecenia „Wyślij pomocnika”: zlecenie przyjęte z wypożyczonymi maszynami, pomocnik je zabiera, po czasie dojazdu zależnym od odległości pojawia się na polu, sam podpina sprzęt i pracuje.

**Multiplayer:** wszystko działa na serwerze, każdy członek farmy ma pełny dostęp (finansowanie, fabryki, cofanie budowy, długi sen, pomocnik). Część akcji sprawdza też sama gra (uprawnienia farmy) – wspólnikowi nadaj uprawnienia albo zrób go zarządcą farmy.

## Instalacja / budowanie

Kilka plików powstaje z zasobów gry (GIANTS Software) i **nie ma ich w repozytorium** – skrypt tworzy je z Twojej instalacji gry:

```
pip install pillow numpy
python tools/build.py --install
```

- `--game "D:/Gry/Farming Simulator 25"` – jeśli gra nie jest w domyślnym folderze Steam,
- bez `--install` zip ląduje w `dist/FS25_MegaPatch.zip`.

Plik musi nazywać się **`FS25_MegaPatch.zip`** – pod tą nazwą mod jest zapisany w zapisach gry.

Konsola (`~`): `mpHelperInfo`, `mpHelperSend <pole>`, `mpLongSleep [miesiące]`, `mpFuelInfo`, `mpFinanceInfo`, `mpProductionInfo`, `mpDiag`.

---

## English

Features: IBC diesel container with a dynamic fuel market, vehicle financing (lease → loan, late fees, repossession), using factories without buying them (fee on output), long sleep of 1–12 months with a forecast, construction undo/redo with 100% refund plus free terraforming and road/parking paint markings, and a contract helper that takes the borrowed equipment, arrives after a distance-based travel time and starts working. Everything is server-side in multiplayer and every farm member has full access.

**Build:** some files are derived from Farming Simulator 25 assets (© GIANTS Software) and are not included. `python tools/build.py --install` (Pillow + numpy) recreates them from your own game installation and installs `FS25_MegaPatch.zip` (keep this file name – savegames reference it).

Farming Simulator is a trademark of GIANTS Software GmbH. This is an unofficial fan mod.
