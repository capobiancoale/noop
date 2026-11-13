# NOOP: dal "mostrare i dati" al "dirti cosa fare"

Scaletta di lavoro per chi implementa. Stato: in corso di sviluppo.
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
   - Carboidrati in g/kg al giorno: giornata leggera 3–5; mantenimento e spinta 5–7; obiettivo
     resistenza in giornata di spinta 6–10; obiettivo dimagrire 3–5. Mai dosi di insulina (vedi §6d).
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

Trovati da una revisione automatica del codice. Quelli segnati **[verificato]** li ho ricontrollati
io sulle righe indicate; gli altri vanno ricontrollati prima di correggerli. Niente è stato provato
sul telefono: i punti di impaginazione sono stime.

### 6a. Allenamenti e WOD

Dati sbagliati (prima questi):
1. **[verificato] Un WOD salvato senza risultato registra 0:00, che diventa il record.**
   `WodEditorView.swift:54` parte con `resultKind = .time` e `:280` salva `(Int(resMin) ?? 0)*60 + …`
   anche con i campi vuoti. Poi `WodLogView.swift:164` prende il minimo. Correzione: campi vuoti →
   `resultKind = .none` e `resultSeconds = nil`; secondi limitati a 0–59; ignorare i tempi a 0 nei record.
   Serve anche una migrazione o un filtro per i WOD già salvati con 0 secondi.
2. **[verificato] Il record non distingue RX da scalato.** `WodLogView.swift:164-172` e
   `WodDetailView.swift:512`. Correzione: record separati per RX e scalato (campo `rx` di `WodLogRow`).
3. **[verificato] Reimportare lo stesso testo o CSV duplica i WOD.** `WodImportView.swift:181`
   salva righe con id nuovi a ogni lettura. Correzione: prima di salvare, riconoscere i WOD con stessa
   data e stesso titolo e chiedere se saltarli o sostituirli.
4. **[verificato] "Questa settimana" in Allenamenti parte dall'ultimo allenamento, non da oggi.**
   `WorkoutsView.swift:551-553`. Dopo una pausa mostra una settimana vecchia e contraddice la scheda
   del carico. Correzione: ancorare a oggi, come già fatto in `TrendsView.swift:87-91`.
5. **[verificato] Carboidrati "0 g" attorno al WOD quando il dato manca.** `WodDetailView.swift:310-313`
   (valori iniziali 0.0 alle righe 51-52). Per un diabetico "0 g" e "dato assente" non sono la stessa
   cosa. Correzione: valori opzionali e trattino con spiegazione quando mancano.
6. Record raggruppati distinguendo maiuscole e minuscole (`WodLogView.swift:96`) mentre la cronologia
   no (`WodStore.swift:151`): "Fran" e "fran" danno conteggi incoerenti. **[verificato la riga 96]**
7. Punteggio AMRAP `giri*100 + ripetizioni` (`WodLogView.swift:167`): sbaglia con 100 o più
   ripetizioni extra. **[verificato]**
8. Tempo limite: il campo tiene solo i minuti interi, 90 s diventano 60 s (`WodEditorView.swift:237`).
9. Giorno del WOD calcolato con 86.400 s fissi (`WodDetailView.swift:176-178`): sbaglia nei giorni
   del cambio d'ora.
10. Scheda del carico: "carico 7 giorni" è una somma, "settimana tipo" è una media × 7
    (`TrainingLoadCard.swift:109`): con giorni mancanti i due numeri non tornano con il rapporto mostrato.

Testi in inglese su telefono italiano:
11. **[verificato]** "reps", "RX", "kg" costruiti come stringhe semplici (`WodLogView.swift:153, 170, 185, 187`).
12. **[verificato]** Titolo del dettaglio allenamento in inglese (`WorkoutDetailView.swift:61, 156`
    usa `displaySport`; l'elenco usa `localizedSport`).
13. **[verificato]** Menu "Rinomina come" con nomi sport in inglese (`WorkoutsView.swift:1363`).
14. Selettori Tipo e Formato del WOD in inglese pur avendo le traduzioni (`WodEditorView.swift:70, 81`).
15. **[verificato]** Frase della caffeina con un numero nudo al posto dell'etichetta
    (`InsightsHubView.swift:763`): "Con 2 stanotte…".

Stati vuoti e impaginazione:
16. Filtro o ricerca senza risultati: schede vuote senza messaggio (`WorkoutsView.swift:140, 613`).
17. "0,0 km" e "0" calorie per chi fa solo CrossFit (`WorkoutsView.swift:759-766`): mostrare un trattino.
18. Riga dei filtri che può uscire dallo schermo con filtri attivi (`WorkoutsView.swift:404-490`). Stima.
19. Seconda riga dell'allenamento troncata prima di kcal, distanza e bpm (`WorkoutsView.swift:1259, 1316`). Stima.
20. In Trend due schede con lo stesso titolo "Week in review", la seconda è la media del periodo
    scelto (`TrendsView.swift:378, 417`).
21. "Ripetizioni fatte" si inserisce ma non compare da nessuna parte (`WodEditorView.swift:108`).

### 6b. Progressi nel sollevamento pesi (richiesta dell'utente, i dati ci sono già)

`WodLogRow.movements` (`WodStore.swift:22-37`) conserva nome, ripetizioni, schema ("5x5"),
ripetizioni fatte, carico e carico RX per ogni WOD. Oggi i progressi esistono solo per titolo del WOD.
Da aggiungere, con un motore puro `StrengthProgress` in `StrandAnalytics` + test:
- cronologia e grafico **per movimento** (Back Squat, Clean…), con nomi normalizzati senza
  distinguere maiuscole;
- **1RM stimato** con Epley, `kg × (1 + rip/30)`, solo quando ci sono carico e ripetizioni (1–10 rip),
  sempre etichettato "stimato";
- **volume settimanale** (serie × rip × kg) solo dove lo schema si legge con certezza ("NxM" o
  ripetizioni intere); il resto escluso e dichiarato;
- **segno di record** sul movimento;
- i WOD senza risultato ma con carichi nei movimenti devono comunque entrare nei progressi
  (oggi `WodLogView.swift:99-100` li scarta).
Questi dati vanno anche nel blocco "Massimali" del contesto del Coach (§4, punto 7).

### 6c. Oggi, Sonno, Salute

Dalla seconda revisione automatica, **non ricontrollata riga per riga**. Attenzione: ha letto la Today
classica (`TodayView.swift`); l'utente usa quella "liquid" (`Strand/Liquid/LiquidTodayView.swift`),
quindi ogni punto su Today va prima cercato lì.

Testi in inglese:
1. Scheda "Readiness" del Charge: `ReadinessEngine` restituisce frasi inglesi (`TodayView.swift:1590-1627`).
   La Today liquid le ricostruisce già da chiavi (`signalRow`); fare lo stesso nella classica.
2. Lista di controllo dell'Età fitness in inglese (`HealthView.swift:970, 973`).
3. Suggerimento "Swipe" / "Tap" nella barra della data (`TodayView.swift:977`).
4. Errore di sincronizzazione in inglese e con "this Mac" su iPhone (`BLEManager.swift:1684, 1740`).
5. Etichetta "ON-DEVICE" sotto gli anelli (`TodayView.swift:745`).
6. Nomi degli sport in inglese nelle tessere allenamento di Today (`TodayView.swift:3358, 139`).

Valori che possono ingannare:
7. Calorie: mostrano l'ultimo giorno disponibile anche se non è quello scelto (`TodayView.swift:3167, 3338`).
8. Passi con didascalia "oggi" anche sui giorni passati (`TodayView.swift:3305`).
9. Stress 0–3 arrotondato a intero: 0,4 diventa "0" (`TodayView.swift:2182`).
10. Sonno: "Ieri notte" mostrato anche quando il dato è di una notte precedente
    (`SleepView.swift:351, 396, 1583`, lettura con `series.last`).
11. Efficienza del sonno: frazione 0–1 stampata come percentuale ("1 %") in un ramo raro (`TodayView.swift:4203`).
12. Frequenza respiratoria ed Età fitness mostrate senza data anche se vecchie di giorni.
13. Notti importate: ipnogramma disegnato con fasi inventate (`SleepView.swift` circa 2700). Va tolto o
    dichiarato chiaramente.

Impaginazione in italiano (stime):
14. Etichette al centro degli anelli che escono dall'anello (`TodayView.swift:2751, 2826, 2841`).
15. Didascalie troncate nelle tessere dei parametri vitali e delle metriche (`HealthView.swift:1259`).
16. Righe delle fasi del sonno con colonne da 56 e 38 punti: "PROFONDO" non ci sta (`SleepView.swift:1007`).
17. Riga dell'Età fitness troppo stretta (`HealthView.swift:803-835`).

## 6d. Decisioni prese dopo la prima stesura

- **Carboidrati: sì, come intervallo giornaliero** di nutrizione sportiva (g/kg secondo il tipo di
  giornata e l'obiettivo). **Insulina: mai.** L'app non calcola boli e non propone modifiche a basale,
  rapporto insulina/carboidrati o sensibilità: lo fa Loop.
- Le impostazioni di terapia dell'utente **non vanno scritte nel repository** (è pubblico). Se servono
  al Coach come contesto, le inserisce l'utente nell'app, restano sul telefono e si attivano con un
  interruttore; il divieto di suggerire dosi resta.
- **Widget iPhone**: oltre a Charge, Effort e Rest devono mostrare il consiglio del giorno, con una
  grafica più curata. `WidgetSnapshot` (`StrandiOSShared/WidgetSnapshot.swift`) porta i campi del
  piano come valori semplici (il widget non collega `StrandAnalytics`); testi nel catalogo del widget
  (`StrandiOSWidgets/Localizable.xcstrings`).
- **Tolto da Oggi il grafico "Cuore e glicemia"** (resta nella schermata del WOD).
- Un solo punto calcola il piano per scheda, Coach e widget: `Strand/Data/DayPlanBuilder.swift`.

## 7. Ordine consigliato e rilascio

1. §5 (piccolo, serve subito per Ollama) → build TestFlight.
2. §1 + §2 + §3 insieme (motore, obiettivo, scheda) → build.
3. §4 (contesto del Coach, usa il motore del §1) → build.
4. §6a punti 1–5 (dati sbagliati) → build.
5. §6b (progressi nei pesi), poi §4b e il resto del §6.

Per ogni passo: test dei pacchetti in locale, push sulla branch di sviluppo, CI verde, cherry-pick
sulla branch di build, controllo che la build arrivi su TestFlight (gli errori 500 di Apple e
"job not acquired by runner" si risolvono rilanciando i job falliti).

## 8. Cose aperte che non fanno parte di questo piano

- Lo script Ollama (`Tools/coach/setup_ollama_mac.sh`) non è ancora stato provato su un Mac vero.
- NOOP_Original: mancano i secret e i passaggi Apple (guida in quel repository).
