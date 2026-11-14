# Plán ověření funkčnosti a kontroly bugů

Podklad pro každé vydání. Cíl: odhalit regrese dřív než je uživatel uvidí, a když
se objeví, mít u chyby dost kontextu na to ji rovnou opravit.

Vrstvy jdou od nejlevnější (vteřiny) po nejdražší (desítky minut u ručního
prokliku).

## 1. Automatické brány — povinné před každým mergem

| # | Příkaz | Co dokazuje | Čas |
|---|--------|-------------|-----|
| 1 | `cargo test` | logika, parsery, layout testy | ~15 s |
| 2 | `cargo clippy --all-targets` | žádná nová varování v dotčených souborech | ~1 min |
| 3 | `cargo build --release` | release profil se zkompiluje | ~5 min |
| 4 | `git status --short` | v commitu není `DBG`/`eprintln!`/`.shot.png` | ~1 s |

Pravidla:

- Test, který selže, se opravuje, ne maže. `#[ignore]` se zapisuje do session
  poznámky s důvodem.
- `cargo fmt --check` v repu **není** zelené (formátování je historicky
  nekonzistentní), takže se nepoužívá jako brána. Formátuj jen editované bloky.
- Varování `deprecated: egui::Id::new` a mrtvý kód v `ui/components.rs` jsou
  známé a nepočítají se jako regrese. Nová varování ano.

## 2. Headless UI harfa — layout se dá měřit bez okna

egui umí projít widget bez okna, takže rozbité rozvržení jde zachytit testem.
Vzor (`src/ui/chat_info.rs`, test `gallery_rows_fit_the_panel_width`):

```rust
let ctx = egui::Context::default();
let mut width = 0.0;
let mut output = ctx.run_ui(Default::default(), |ui| {
    ui.set_max_width(300.0);           // šířka panelu
    media_gallery(ui, &mut state, &chat);
    width = ui.min_rect().width();     // jak široký obsah Opravdu je
});
output.textures_delta.clear();         // v testu se nenahrávají textury
assert!(width <= 300.0, "rows are {width} px wide");
```

Co tím pokrýt (chybí, v tomto pořadí podle rizika):

1. **Dlouhé zprávy** — `MessageBubble` v okně širokém 320, 480 a 900 px: bublina
   nesmí přesáhnout `available_width * 0.72 + okraje`.
2. **Dlouhý název chatu** (`chat_list.rs`) — řádek se musí zkrátit, ne roztáhnout.
3. **Dlouhý název souboru v bublině dokumentu** — vykreslovalo se přes
   `painter.text`, což test změří jen přes `min_rect`; ověřit aspoň, že se
   nezmění `media_rect` mimo bublinu.
4. **Composer** s dlouhým textem a přílohami — tlačítka se nesmí posunout mimo
   okno.
5. **Settings** — nejdelší české popisky v panelu 320 px.

Každý nový panel nebo řádek se seznamem proměnných délek dostane takový test.
Je to nejlepší dostupná obrana: přesně tímhle se našel bug 944 px v panelu 300 px.

## 3. Aktualizace — end-to-end, ne jen „tlačítko reaguje“

Instalátor je nejrizikovější část: běží odpojeně po ukončení aplikace a nemá
žádné UI. Ověřuje se na skutečném release balíčku.

1. Ověřit, že release má 4 assety:
   `gh release view v<verze> --json assets -q '.assets[].name'`
2. Ověřit, že balíček je opravdu zip a že ho rozbalí systémový bsdtar
   (GNU tar z Gitu zip neumí — to byla příčina 0.3.2):
   `/c/Windows/System32/tar.exe -tf <balicek>.zip` → vypíše obsah.
3. Sandbox instalace:
   ```sh
   mkdir -p /c/Users/$USER/AppData/Local/Temp/updtest/install
   echo stara > /c/Users/$USER/AppData/Local/Temp/updtest/install/warust.exe
   ```
   Spustit skript z aplikace (nebo jeho text z `windows_update_script`) s `pid`,
   které neexistuje, a zkontrolovat: `warust.exe` přepsaný, `ffmpeg.exe`,
   `ffprobe.exe`, `FFMPEG-NOTICE.txt` zkopírované, staging smazaný, zip smazaný.
4. Zkontrolovat `%TEMP%\warust-update.log` — každý běh tam musí mít řádek
   `--- aktualizace <datum>`, při chybě `rozbaleni selhalo, zustava stara verze`.
5. V aplikaci: Update dialog → stáhnout → aplikace se ukončí → nová verze
   naběhne → *Nastavení → O úložišti* ukazuje novou verzi → další kontrola
   aktualizací už nic nenabízí.
6. Regresní past: stará verze v sobě má starý instalátor. Po vydání opravy
   zkontrolovat, že release notes říkají, jak aktualizovat ručně.

## 4. Manuální smoke — 20 minut před vydáním

Projít v pořadí; u každého bodu stačí „projde / neprojde + poznámka“.

| # | Oblast | Kroky | Očekávané |
|---|--------|-------|-----------|
| 1 | Start | spustit `target/release/warust.exe` | okno naběhne, v logu `Starting Warust v<verze>` |
| 2 | Přihlášení | QR nebo párování kódem | stav `Connected`, historie se dosynchronizuje |
| 3 | Seznam chatů | přepínat, hover, hledat | plynulý cross-fade, žádné skoky šířky |
| 4 | Konverzace | otevřít 3 různé chaty | fade při přepnutí, scroll na poslední zprávu |
| 5 | Zprávy | odeslat text, Enter/Shift+Enter | odesláno, composer vyčištěn, drafty drží |
| 6 | Média | obrázek, video, hlasovka, dokument | stahování, přehrávání, otevření souboru |
| 7 | Specifické | sticker, anketa, poloha, kontakt, view-once | každá bublina se vykreslí a funguje |
| 8 | Úpravy | edit, smazat, přeposlat, připíchnout | stav se propíše i po restartu |
| 9 | Hledání | hledání zpráv + filtry | výsledky sedí, skok na zprávu blikne a zhasne |
| 10 | Info panel | otevřít, taby galerie, **klik na odkaz** | řádky zkrácené, nic nepřeteče, „Otevřít“ spustí prohlížeč |
| 11 | Nastavení | každý tab, změna preferencí | změna se uloží (`state.dirty`), po restartu drží |
| 12 | Oznámení | `warust.exe --test-notification` | toast se objeví, v logu `test notification result: true` |
| 13 | Tray | zavřít křížkem, otevřít z ikony | aplikace zůstane běžet, zprávy dál chodí |
| 14 | Nahrávání | hlasovka start/stop, Storno | soubor vznikne jen po odeslání |
| 15 | Aktualizace | viz sekce 3 | nová verze naběhne |

Zvlášť se testuje **úzké okno**: zmenšit na ~500×700 a projít body 3, 4, 6, 10.
Přesně v úzkém okně se projevil bug s galerií (944 px obsah v panelu 300 px).

## 5. Regresní checklist podle posledních změn

| Změna | Co znovu ověřit |
|-------|-----------------|
| `fix(updater)` bsdtar + staging | sekce 3, celá |
| `fix(chat-info)` šířka řádků | bod 10 + úzké okno |
| `feat(ui)` animace | body 3, 4, 9 — fade nesmí zůstat „zamrzlý“ v poloprůhlednu |
| připnuté zprávy, galerie | bod 8 a 10 |
| hlasovky, skupiny | body 6, 7, 14 |

## 6. Když se objeví chyba

Zapsat rovnou, nestačí „nefunguje“:

- **verze** (Nastavení → O aplikaci) a **jestli je to release, nebo build z mainu**;
- **postup** (1., 2., 3. …) a co se stalo místo očekávaného;
- **screenshot** rozbitého stavu (i s okolím, ne výřez);
- **log**: spustit z terminálu (`RUST_LOG=warust=debug warust.exe`) a přiložit
  posledních ~50 řádků; u aktualizací navíc `%TEMP%\warust-update.log`;
- **opakovatelnost**: stane se to vždy, nebo jen po nějaké akci (klik, resize,
  přepnutí tabu)?

Závažnost:

- **P0** — aplikace se nespustí, nejde se přihlásit, ztráta dat, rozbité
  rozvržení celého okna. Blokuje vydání.
- **P1** — funkce nefunguje (neodešle, nepřehraje, neaktualizuje). Blokuje
  vydání, pokud jde o poslední změněnou oblast.
- **P2** — kosmetika, zkrácený text, drobná animace. Jde do dalšího vydání.

## 7. Výstupní kritéria pro vydání

- brány 1–4 zelené, testů `0 failed`;
- manuální smoke projít celý, u P0/P1 nic otevřeného;
- aktualizace ověřená na skutečném balíčku (sekce 3), včetně logu;
- `CHANGELOG.md` má sekci s datem a release notes odpovídají realitě.

## 8. Známé mezery a co s nimi

- **Aplikace nepíše log do souboru**, jen na stdout. U odpojeného okna není co
  přiložit — stálo by za to přidat `%LOCALAPPDATA%\warust\warust.log` s rotací.
  Do té doby se QA log sbírá spuštěním z terminálu.
- **Žádné automatické UI testy** (klikání, screenshoty). Nejblíž je headless
  harfa v sekci 2; ta měří rozvržení, ne interakce.
- **`cargo fmt --check` neprochází** — repozitář není srovnaný, brána by blokovala
  každý commit. Srovnat jednorázově, pak zapnout.
- **Update jde ověřit jen ručně** — chybí `--test-update` flag, který by stáhl
  a rozbalil balíček do dočasné složky bez výměny souborů. Levná varianta:
  přidat vedle `--test-notification` v `src/main.rs`.