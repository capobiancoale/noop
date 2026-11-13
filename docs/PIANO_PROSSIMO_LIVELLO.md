# NOOP: dal "mostrare i dati" al "dirti cosa fare"

Scaletta di lavoro per chi implementa. Stato: **niente di quanto segue è stato scritto**, è solo il piano.
Branch di partenza: `claude/blissful-mayer-0dvnwt` (commit `1ebb664e`).

Obiettivo dell'utente: l'app oggi mostra soprattutto numeri. Deve dire **come passare la giornata**,
**come migliorare** e **cosa mangiare**, in base a recupero, sonno, carico, età, peso, sesso e
**obiettivo personale**. In più il Coach (chat AI, ora usabile con Ollama sul Mac) deve conoscere
davvero i dati dell'utente.

## 0. Regole per chi implementa

- Utente: atleta CrossFit italiano con diabete di tipo 1, solo iPhone, interfaccia in italiano.
- **Non è un dispositivo medico.** Mai quantità di carboidrati né dosi di insulina, mai valori inventati:
  se un dato manca, la riga non compare o dice che manca.
- Logica nuova in funzioni **pure** dentro `Packages/StrandAnalytics` (niente orologio, niente
  UserDefaults: si passa tutto come parametro), con test in `Tests/StrandAnalyticsTests`.
  Le viste ricevono chiavi e numeri e costruiscono loro il testo localizzato, come fa già
  `signalRow` in `Strand/Liquid/LiquidTodayView.swift:623` per `ReadinessEngine`.
- Ogni stringa nuova va in `Strand/Resources/Localizable.xcstrings` con la traduzione `it`
  (chiave = testo inglese). I nomi dei punteggi restano Charge / Effort / Rest.
- Numeri a schermo con il separatore del telefono (niente `String(format: "%.1f")` mostrato all'utente).
- Sviluppo su `claude/blissful-mayer-0dvnwt`; si aspetta che la CI passi; poi `git cherry-pick -x`
  su `claude-automatic-build` (il push di quella branch fa partire la build TestFlight).
  Nessuna PR. Non toccare `main`. Non impostare `ENABLE_NUKE_CERTS` né `MATCH_REPO`.
- Test dei pacchetti su Linux: toolchain Swift 6.1.2
  (`https://download.swift.org/swift-6.1.2-release/ubuntu2404/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-ubuntu24.04.tar.gz`),
  poi `swift test` dentro `Packages/StrandAnalytics`. Il target dell'app si compila solo in CI.

## 1. Motore "Piano di oggi" (nuovo)

File: `Packages/StrandAnalytics/Sources/StrandAnalytics/DayPlan.swift` + `DayPlanTests.swift`.

### Ingressi
| Dato | Da dove |
|---|---|
| righe giornaliere (Charge, Effort, sonno, HRV, FC a riposo) | `[DailyMetric]` (`repo.days`) |
| chiave del giorno | `selectedDayKey` di Today |
| fabbisogno e debito di sonno | serie `sleep_need_min`, `sleep_debt_min` |
| orari di risveglio delle ultime 14 notti (minuti dopo mezzanotte) | `repo.sleeps` (`CachedSleepSession.endTs`), solo notti ≥ 3 h |
| carico | `TrainingLoad.summary(days:today:)` (già usato da `TrainingLoadCard`) |
| età, sesso, peso, altezza | `ProfileStore` |
| obiettivo | nuovo, vedi §2 |

### Uscite (solo chiavi e numeri, niente frasi)
1. **Allenamento**: `push` / `maintain` / `easy`, più l'elenco dei motivi.
   - Base dal Charge: ≥ 67 push, 34–66 maintain, < 34 easy (le stesse soglie del prompt del Coach,
     `Strand/AI/AICoach.swift:212`). Senza Charge: `maintain` con motivo `noCharge`.
   - Sonno della notte < 6 h o < 70 % del fabbisogno: scende di un gradino.
   - Rapporto di carico ≥ 1,5 (`TrainingLoad.Band.sharpRise`): al massimo `maintain`.
   - 3 o più giorni duri di fila (Effort ≥ 75° percentile dei propri ultimi 28 giorni, servono
     almeno 14 giorni con Effort): al massimo `easy`.
   - Nessun obiettivo numerico di Effort: non c'è una base verificata per darlo.
2. **Sonno di stasera**: durata = fabbisogno (se manca, 8 h) + recupero del debito fino a 60 min;
   ora di andare a letto = mediana dei risvegli − durata − 15 min. Senza almeno 5 notti: solo la durata.
3. **Alimentazione** (stime, etichettate come tali):
   - Metabolismo a riposo, Mifflin-St Jeor: `10·kg + 6,25·cm − 5·età + 5` (uomo) / `− 161` (donna);
     altro sesso: media dei due.
   - Energia del giorno = riposo × 1,4 (easy) / 1,6 (maintain) / 1,8 (push), mostrata come intervallo ±5 %.
   - Obiettivo: dimagrire −15 %; massa/forza +7 %; altri 0. Mai sotto il metabolismo a riposo.
   - Proteine in g/kg al giorno: salute 1,2–1,6; prestazione e resistenza 1,4–2,0; forza 1,6–2,2;
     dimagrire 1,6–2,4. Nota fissa: "se il tuo medico ti ha dato indicazioni diverse, valgono quelle".
   - Liquidi: 2,5 L uomo / 2,0 L donna, +0,5 L nei giorni maintain e push.
   - **Carboidrati: nessuna quantità.** Se ci sono dati di glicemia (`hasGlucoseBlock` in Today) la
     scheda dice che con il diabete di tipo 1 si decidono con il team diabetologico.
   - Se età, peso o altezza mancano (0): niente numeri, invito a completare il profilo.
4. **Su cosa lavorare** (al massimo 3, in quest'ordine di priorità):
   debito di sonno ≥ 60 min; media sonno 7 giorni sotto il fabbisogno di oltre 45 min;
   risvegli irregolari (deviazione standard > 60 min su 14 notti); carico ≥ 1,5 oppure < 0,8;
   HRV media 7 giorni oltre il 10 % sotto la media 30 giorni; FC a riposo media 7 giorni ≥ 5 bpm
   sopra la media 30 giorni. Ogni voce porta i suoi numeri.

### Test minimi
Soglie del Charge ai bordi (33/34/66/67); ogni regola che abbassa il gradino; profilo incompleto;
energia mai sotto il riposo; ora di letto che attraversa la mezzanotte; meno di 5 notti; ordine e
tetto di 3 voci in "su cosa lavorare".

Le soglie vanno riportate nel commento in testa al file con la fonte (Mifflin 1990; ISSN position
stand sulle proteine 2017; EFSA 2010 per l'acqua; Gabbett 2016 con il limite di Impellizzeri 2020 già
scritto in `TrainingLoad.swift`).

## 2. Obiettivo personale (nuovo)

- Enum `DayPlan.Goal`: `performance`, `strength`, `fatLoss`, `endurance`, `health`.
- Salvataggio: `ProfileStore` (`Strand/Data/Profile.swift`), nuova proprietà `goal` con chiave
  UserDefaults `profile.goal`, default `performance`.
- Scelta in due punti: nel profilo dentro `Strand/Screens/SettingsView.swift` (accanto a età/peso) e
  con un `Menu` sull'etichetta dell'obiettivo dentro la scheda del piano.

## 3. Scheda "Piano di oggi" in Today (nuova)

- File nuovo `Strand/Screens/DayPlanCard.swift`; inserita in
  `Strand/Liquid/LiquidTodayView.swift` subito dopo `heroCard` (che contiene `stateVerdict`, riga 567)
  e prima del blocco glicemia. Solo quando `selectedDayOffset == 0`.
  La stessa scheda va anche nella Today classica (`Strand/Screens/TodayView.swift`).
- Contenuto: tre righe (Allenamento, Sonno stasera, Alimentazione), sotto "Su cosa lavorare",
  in alto a destra l'obiettivo, in fondo "Chiedi al Coach" (apre la tab Coach via `NavRouter`).
- Il piano si calcola in `load()` insieme agli altri `@State` e si tiene in uno `@State`
  (non ricalcolare nel `body`; il file ha già avuto problemi di type-checking: sezioni type-erased).
- Stato vuoto: se manca il Charge la scheda lo dice e dà comunque sonno e alimentazione.
- Accessibilità: un'etichetta unica per riga; testi lunghi con `fixedSize(horizontal:false, vertical:true)`.

## 4. Coach: contesto completo

Oggi `buildContext()` (`Strand/AI/AICoach.swift:644`) manda solo 14 righe giornaliere, medie a 30
giorni e 6 allenamenti. Non manda: data di oggi, profilo, obiettivo, dettaglio del sonno, WOD,
carico, lingua. La riga "rest" contiene le ore di sonno mentre il prompt la descrive come punteggio 0–100.

- File nuovo `Packages/StrandAnalytics/Sources/StrandAnalytics/CoachContext.swift` (funzioni pure,
  testo in inglese perché è per il modello) + test. Blocchi:
  1. `Today is <weekday> yyyy-MM-dd, HH:mm local.` e se il Charge di oggi c'è già.
  2. Profilo: età, sesso, peso, altezza, FC max (`ProfileStore.storedHRMax()`), obiettivo.
  3. Piano di oggi (uscite del §1) in 4–5 righe: così il Coach spiega il piano invece di inventarne uno.
  4. Ultima notte: ora di inizio e fine, durata, efficienza, profondo/REM/leggero, punteggio Rest,
     fabbisogno, debito.
  5. Carico: settimana contro il solito, rapporto e fascia.
  6. Ultimi 5 WOD (30 giorni): data, titolo, formato, risultato, RPE, RX, movimenti con carichi
     (`WodLogRow`, `WodMovement` in `Packages/WhoopStore/Sources/WhoopStore/WodStore.swift`).
     Niente note libere.
  7. Massimali: per movimento, carico migliore degli ultimi 90 giorni e ultimo carico (max 8 movimenti).
  8. `Reply in <lingua dell'app>.` (da `Bundle.main.preferredLocalizations.first`).
  9. Paletto fisso, **dentro il contesto e non nel prompt modificabile**: nessuna quantità di
     carboidrati, nessuna dose di insulina, nessuna diagnosi.
- `AICoachEngine.buildFullContext()` (riga 514) monta i blocchi. Correggere `dayLine` (riga 704):
  "sleep 7.2h" e, a parte, "rest <punteggio>". Tetto: circa 2.500 token in tutto.
- "Today's brief" (riga 507) è una stringa fissa in inglese: usare `String(localized:)` e aggiungere `it`.
- Aggiornare `defaultSystemPrompt` (riga 212): citare WOD, obiettivo e piano; dire di partire dal piano.
- Test esistenti da tenere verdi: `StrandTests/AICoachPromptAndStressTests.swift`.

### 4b. Glicemia nel Coach (facoltativo, a scelta dell'utente, spento di default)
- Nuovo interruttore sotto "Let the coach use my data" in `Strand/Screens/CoachView.swift`
  (stesso stile di `onDeviceSignalsBar`, riga 116), visibile solo se esistono dati di glicemia.
- Solo riepiloghi giornalieri degli ultimi 14 giorni, con le chiavi di
  `DatabricksCsv.glucoseAllowlist` (`Packages/StrandImport/.../DatabricksCsv.swift:400`), letti con
  `repo.series(key:source: Repository.appleHealthSource)`. Mai letture singole.
- Con l'interruttore acceso il paletto del punto 9 resta e si rafforza ("glucose is background only").

## 5. Coach: collegamento a Ollama più solido

Problemi verificati nel codice:
- `connectCustom()` (`AICoach.swift:334`) segna "collegato" **senza provare il server**: un indirizzo
  sbagliato sembra funzionare finché non si manda una domanda.
- Nessun aiuto se manca `/v1` o `http://` nell'indirizzo.
- La richiesta di chat (`Strand/AI/Providers/Custom.swift`, `chat`) usa il timeout di default di
  60 s: un modello locale al primo avvio può metterci di più.

Da fare:
1. `connectCustom()` asincrono: prova `GET /models`; collegato solo se risponde. Nuovo
   `@Published var connecting` per mostrare l'attesa sul pulsante "Connect" (`CoachView.swift:285`).
2. Funzione pura `customURLCandidates(_:)`: aggiunge `http://` se manca lo schema e prova anche la
   variante con `/v1`; salva in `customBaseURL` quella che risponde.
3. Se il server risponde 404/405 a `/models` ma è raggiungibile: collegare lo stesso.
4. Errore di rete con indicazioni pratiche (Mac acceso e sveglio, stessa Wi-Fi, permesso "Rete locale").
5. Dopo il collegamento scegliere `noop-coach` se è nella lista, altrimenti il primo modello.
6. `req.timeoutInterval = 180` nelle richieste del provider Custom.
7. Aggiungere `NSLocalNetworkUsageDescription` in `project.yml` (target iOS) e in
   `StrandiOS/Resources/InfoPlist.xcstrings` con `it`: oggi manca, quindi iOS mostra un testo generico.
8. Test: `StrandTests/AICoachRefreshModelsRaceTests.swift` usa `fetchModelsOverride`; riusarlo.

## 6. Difetti trovati dalla revisione delle schermate

Due revisioni automatiche (Today/Sonno/Salute e Allenamenti/WOD/VO2max/Trend) sono ancora in corso
mentre scrivo. I risultati vanno **verificati sul codice** prima di correggerli e aggiunti qui sotto.

_(da completare)_

## 7. Ordine consigliato e rilascio

1. §5 (piccolo, serve subito per Ollama) → build TestFlight.
2. §1 + §2 + §3 insieme (motore, obiettivo, scheda) → build.
3. §4 (contesto del Coach, usa il motore del §1) → build.
4. §4b e §6.

Per ogni passo: test dei pacchetti in locale, push sulla branch di sviluppo, CI verde, cherry-pick
sulla branch di build, controllo che la build arrivi su TestFlight (gli errori 500 di Apple e
"job not acquired by runner" si risolvono rilanciando i job falliti).

## 8. Cose aperte che non fanno parte di questo piano

- Lo script Ollama (`Tools/coach/setup_ollama_mac.sh`) non è ancora stato provato su un Mac vero.
- NOOP_Original: mancano i secret e i passaggi Apple (guida in quel repository).
