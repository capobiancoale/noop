# NOOP su Databricks: guida passo passo

Questa guida porta ogni mattina i riepiloghi di **sport e sonno** di NOOP su **Databricks Free Edition**, così puoi
guardarli in una dashboard e farci domande in italiano: sonno, recupero, VO2max, pesi sollevati nei WOD, zone di
frequenza cardiaca, Effort.

NOOP non è un dispositivo medico: i numeri sono stime a scopo informativo, non servono a decidere cure o dosi.

Come funziona, in breve:

1. Ogni mattina un'**automazione dei Comandi rapidi** dell'iPhone esegue l'azione di NOOP **Carica su Databricks**.
2. NOOP scrive sei piccoli file CSV e li **carica** nel tuo volume Databricks, con il token che metti nel comando
   rapido.
3. Ogni giorno un **job** di Databricks rilegge tutti i file e ricostruisce le tabelle.
4. Una **dashboard** e uno spazio **Genie** leggono le tabelle.

NOOP si collega a internet solo durante quell'azione, solo verso l'indirizzo Databricks che scrivi tu (accetta solo
indirizzi `….databricks.com` o `….azuredatabricks.net`), e **non salva il token**: resta nel comando rapido, che
lo passa a NOOP a ogni esecuzione. Se preferisci che NOOP non tocchi mai la rete, in fondo al punto 4 c'è la
variante in cui è il comando rapido stesso a caricare i file.

## Cosa viene esportato, e cosa mai

Viene esportato solo un elenco fisso (non "tutto tranne qualcosa"):

| File | Contenuto |
|---|---|
| `days` | un giorno per riga: Charge, Effort, Rest, ore di sonno e fasi, battito a riposo, HRV, SpO2, respiro, temperatura cutanea, passi |
| `sleeps` | ogni sonno (notti e riposini): orari, durata a letto, fasi, efficienza |
| `workouts` | allenamenti: sport, durata, battito, calorie, Effort, minuti in ogni zona cardiaca |
| `wods` | i WOD che hai registrato: titolo, tipo, risultato, RPE, RX, minuti per zona |
| `wod_movements` | i movimenti di ogni WOD con ripetizioni e carichi |
| `metrics` | valori giornalieri di un elenco fisso di misure di sport e sonno (VO2max, dettagli del Rest, zone, ...) |
| `glucose` | **solo se attivi "Includi glicemia e insulina"** (punto 4): i riepiloghi giornalieri di glicemia, insulina e carboidrati che NOOP legge da Salute, dove li scrive Loop (tempo in range, sotto e sopra, CV, ipoglicemie, valori notturni, basale e boli, carboidrati) |

**Non vengono mai esportati**: le singole letture della glicemia (nemmeno con l'opzione attiva vanno oltre i
riepiloghi del giorno), il resto dell'alimentazione, pressione, peso e composizione corporea, umore, ritmo
irregolare, diario, note dei WOD e dei movimenti, e nessun dato grezzo del sensore (battito secondo per secondo,
ecc.). Titoli dei WOD e nomi dei movimenti invece sì, perché servono per i grafici sui pesi.

Glicemia e insulina sono dati sanitari: prima di attivare l'opzione leggi il punto 8 su cosa garantisce (e cosa no)
Databricks Free Edition. Senza l'opzione la tabella `glucose` resta vuota.

## 1. Iscriversi a Databricks Free Edition e trovare l'indirizzo

1. Vai su Databricks e scegli **Free Edition** (non la "prova gratuita": quella è per le aziende e scade). Ti
   iscrivi con la tua email personale.
2. Quando sei dentro il tuo spazio di lavoro, guarda la barra dell'indirizzo del browser. Ha questa forma:
   `https://dbc-xxxxxxxx-xxxx.cloud.databricks.com/...`
3. L'**host** è la parte tra `https://` e la prima `/` (per esempio `dbc-xxxxxxxx-xxxx.cloud.databricks.com`).
   In questa guida lo trovi scritto come `<host>`: sostituiscilo con il tuo.

## 2. Il token personale

Il token è la chiave con cui il comando rapido carica i file. Chi ha il token può scrivere nel tuo Databricks.

1. In Databricks apri il tuo profilo in alto a destra, poi **Settings** > **Developer** > **Access tokens** >
   **Manage** > **Generate new token**.
2. Come commento scrivi `NOOP comandi rapidi`. Scegli la durata più lunga che ti lasciano.
3. Copia il token (inizia con `dapi...`) **subito**: non te lo mostrano una seconda volta.
4. Incollalo **solo** nel comando rapido (punto 4). Non metterlo in note, email o altri file, e **non condividere
   il comando rapido** con nessuno (anche il link di condivisione porta con sé il token).

Quando il token scade i caricamenti smettono di funzionare (errore 401, vedi punto 9): ne generi uno nuovo e lo
sostituisci nel comando rapido.

## 3. Creare lo schema e il volume (una volta sola)

Il catalogo che usiamo si chiama `noop_uploads` (già esistente). Dentro verranno creati lo schema `noop` e il
volume `raw`, dove arrivano i file.

1. In Databricks apri **Workspace**, poi il menu **Create** (o i tre puntini) > **Import**, scegli il file
   [`noop_refresh.sql`](noop_refresh.sql) di questa cartella e importalo. Diventa un notebook.
2. Aprilo, in alto a destra come calcolo scegli **Serverless**.
3. Esegui **solo la prima cella** (premi il triangolo ▶ della prima cella). Crea lo schema `noop`, il volume `raw`
   e una piccola tabella `lift_alias`.
4. Controlla: in **Catalog** > `noop_uploads` > `noop` devi vedere il volume `raw`.

Se il tuo catalogo ha un altro nome, prima di tutto: nel notebook usa **Edit** > **Find and replace** e cambia
`noop_uploads` ovunque; poi usa lo stesso nome nell'indirizzo del punto 4.

## 4. Il comando rapido sull'iPhone

Apri l'app **Comandi**, tocca **+** e chiama il comando `NOOP per Databricks`.

1. **Aggiungi azione** > cerca `NOOP` > scegli **Carica su Databricks**.
2. Tocca **Mostra altro** nell'azione e compila:
   - **Indirizzo area di lavoro**: l'indirizzo che vedi nel browser quando sei su Databricks, per esempio
     `https://dbc-xxxxxxxx-xxxx.cloud.databricks.com` (va bene anche incollato con il resto, `?o=...`: NOOP tiene
     solo la parte giusta).
   - **Catalogo**: `noop_uploads`.
   - **Token di accesso**: il token del punto 2 (`dapi…`), così com'è, senza scrivere `Bearer`.
   - **Giorni**: `14` (gli ultimi 14 giorni, oggi compreso; `0` vuol dire tutta la storia).
   - **Includi glicemia e insulina**: spento di default. Acceso, carica anche il settimo file `glucose` con i
     riepiloghi giornalieri di glicemia, insulina e carboidrati. NOOP li prende da Salute, quindi in NOOP deve
     essere attiva l'importazione da Salute con il permesso di leggere glicemia, insulina e carboidrati (e Loop
     deve scriverli in Salute, come fa di default).
3. Tocca ▶ per una **prima prova a mano**. Alla fine compare "Caricati 6 file su Databricks" (7 con la glicemia). Se qualcosa non va,
   compare invece un messaggio che dice cosa correggere (vedi il punto 9).
4. Per caricare **tutta la storia** una volta, metti **Giorni** a `0`, esegui con NOOP aperto (con anni di dati può
   servire più di qualche secondo), poi rimettilo a `14`. Non fa male caricare due volte: ogni caricamento è un file
   nuovo e per ogni giorno, sonno o WOD vince il più recente.
5. Controlla in Databricks: **Catalog** > `noop_uploads` > `noop` > `raw`: devi vedere i file `days__...csv`,
   `sleeps__...csv`, ecc.

**Variante senza rete in NOOP.** Se non vuoi che NOOP si colleghi a internet, usa al posto di "Carica su Databricks"
l'azione **Esporta dati per Databricks**, che restituisce i sei file al comando rapido, e fai caricare i file al
comando rapido stesso:

1. **Esporta dati per Databricks** con **Giorni** `14`.
2. **Ripeti con ogni elemento**, che prende in ingresso i sei file.
3. **Dentro** la ripetizione, **Ottieni contenuti dell'URL**, poi tocca "Mostra altro":
   - **URL**: `https://<host>/api/2.0/fs/files/Volumes/noop_uploads/noop/raw/`, poi la variabile **Elemento
     ripetizione** con la proprietà **Nome** (tocca la pillola blu e scegli **Nome**), poi `?overwrite=true`.
   - **Metodo**: `PUT`.
   - **Intestazioni**: Chiave `Authorization`, Testo `Bearer <token>` (la parola `Bearer`, uno spazio, il token).
   - **Corpo della richiesta**: `File`, con la variabile **Elemento ripetizione** (senza proprietà).

In alternativa per la storia completa, senza iPhone: nell'app NOOP vai in **Impostazioni** > **Diagnostica** >
**Esporta per Databricks (CSV)** (su iPhone si apre il foglio di condivisione, su Mac scegli una cartella) e poi
carica i file dal browser, in **Catalog** > `noop_uploads` > `noop` > `raw` > **Upload to this volume**.

## 5. L'automazione ogni mattina

1. In **Comandi** apri la scheda **Automazione** > **Nuova automazione** > **Ora del giorno**.
2. Imposta le **10:00** e **Ogni giorno**. Tocca Avanti.
3. Aggiungi l'azione **Esegui comando rapido** e scegli `NOOP per Databricks`.
4. Alla fine scegli **Esegui immediatamente** (e spegni "Notifica quando viene eseguito" se non vuoi la notifica).

Cose da sapere: i dati di NOOP sono leggibili solo dopo il primo sblocco del telefono da quando si è acceso, quindi
se l'iPhone si è appena riavviato e non l'hai ancora sbloccato, l'esecuzione può fallire (la mattina dopo riprova e
ricarica gli ultimi 14 giorni, quindi non perdi niente). Il comando rapido non ti avvisa degli errori di rete: ogni
tanto guarda che in `raw` ci siano file recenti.

## 6. Il job che ricostruisce le tabelle

1. In Databricks apri **Jobs & Pipelines** > **Create** > **Job**.
2. Nome del task `noop_refresh`, tipo **Notebook**, sorgente **Workspace**, scegli il notebook `noop_refresh`
   importato al punto 3. Come calcolo lascia **Serverless**.
3. In **Schedules & Triggers** > **Add trigger** > **Scheduled**: ogni giorno alle **10:30** (fuso orario
   `Europe/Rome`).
4. Premi **Run now** per provare (serve che il punto 4 abbia già caricato i file). Alla fine nel catalogo
   `noop_uploads.noop` trovi le tabelle `days`, `sleeps`, `workouts`, `wods`, `wod_movements`, `metrics`, `glucose`
   (vuota senza l'opzione della glicemia), e le viste `lifts`, `lift_progress`, `zones_weekly`, `sleep_weekly`,
   `recovery_daily`, `vo2max`, `glucose_daily`.

Il job gira mezz'ora dopo il comando rapido proprio perché i file devono essere già arrivati.

## 7. Dashboard e Genie

Grafici (sonno, recupero, VO2max, pesi, zone, Effort) e sei domande da fare a Genie sono in
[`dashboard.md`](dashboard.md), con le istruzioni per costruirli.

## 8. Limiti e privacy di Free Edition, onestamente

Da leggere prima di mandare lì i tuoi dati. Fonti:
[limitazioni di Free Edition](https://docs.databricks.com/aws/en/getting-started/free-edition-limitations),
[prova gratuita contro Free Edition](https://docs.databricks.com/aws/en/getting-started/free-trial-vs-free-edition),
[caricare un file con la Files API](https://docs.databricks.com/api/files/v2/upload-file).

- **Solo calcolo serverless**, niente cluster personalizzati. Il notebook e il job girano su serverless, la
  dashboard e Genie su **un solo SQL warehouse** di taglia **2X-Small**.
- **Quota giornaliera**: se la superi, il calcolo si ferma per il resto della giornata (nei casi estremi del
  mese). I dati e le impostazioni restano; riparte quando il limite si azzera.
- **Al massimo 5 task di job in parallelo** per account. A noi ne basta uno.
- **Account inattivi per molto tempo possono essere cancellati**. NOOP tiene tutto anche sul telefono, ma non
  considerare Databricks come l'unica copia.
- **Solo uso non commerciale**. Nessun supporto né garanzia di servizio.
- **Databricks si riserva il diritto di addestrare i suoi modelli sui tuoi dati** (è scritto nel confronto tra
  prova gratuita e Free Edition). È il motivo per cui **glicemia, insulina e dati grezzi non vengono mai
  esportati**. Quello che esporti (sonno, recupero, allenamenti, titoli dei WOD, pesi) lo decidi tu: se non ti
  sta bene, non attivare l'automazione.
- La **Files API** con cui il comando rapido carica i file è indicata da Databricks come *Public Preview*: può
  cambiare.
- NOOP non manda **cancellazioni**: se elimini un WOD o un allenamento in NOOP, resta su Databricks. Per toglierlo
  cancellalo anche lì (o ricostruisci tutto svuotando il volume e ricaricando con **Giorni = 0**).
- I file in `raw` si accumulano (sei piccoli file al giorno, pochi kB l'uno). Se vuoi, ogni tanto cancella i
  vecchi, ma tieni almeno l'ultimo caricamento completo.

## 9. Se qualcosa non va

| Sintomo | Causa probabile e rimedio |
|---|---|
| NOOP dice che Databricks ha rifiutato il token, oppure il comando rapido dà **401** o **403** | Token scaduto, sbagliato o incollato con uno spazio in più; oppure l'host nell'indirizzo è sbagliato. Controlla che sia `Bearer`, uno spazio, il token, e che l'host sia quello della barra del browser. |
| NOOP dice che non c'è un volume a quel percorso, oppure **404** | Il percorso non esiste: il volume non è stato creato (rifai il punto 3), oppure il nome del catalogo, dello schema o del volume nell'indirizzo non coincide (`noop_uploads` / `noop` / `raw`, tutto minuscolo). |
| Le tabelle sono **vuote** o il job dice che non trova file | Non è ancora stato caricato niente: guarda in **Catalog** > `raw`. Fai la prova a mano del punto 4. |
| Il job gira **prima** del caricamento | I dati arrivano il giorno dopo. Controlla gli orari (comando rapido 10:00, job 10:30) e, se serve, premi **Run now** sul job dopo il caricamento. |
| Un'alzata compare con **due nomi** (per esempio `Bs` e `Back Squat`) | Aggiungi una riga alla tabella degli alias, vedi sotto. |
| La dashboard è **lenta** la prima volta | Il SQL warehouse si sta accendendo (può servire mezzo minuto). |
| Un errore dice che la **quota** è esaurita | Aspetta il giorno dopo: i dati non si perdono. |

**Alzata rinominata o scritta in modi diversi.** La vista `lifts` raggruppa le alzate per nome, ignorando maiuscole e spazi
doppi. Se scrivi lo stesso movimento in modi diversi, dagli un nome unico: apri un nuovo notebook o l'editor SQL di
Databricks ed esegui, per esempio,

```sql
INSERT INTO noop_uploads.noop.lift_alias VALUES
  ('bs', 'Back Squat'),
  ('back squat (high bar)', 'Back Squat'),
  ('stacco', 'Deadlift');
```

(a sinistra l'alias, cioè come l'hai scritto nel WOD; a destra il nome che vuoi vedere). La prossima volta che
apri la dashboard le righe sono già unite: `lifts` è una vista, non serve rifare il job.

## Cosa NON è stato provato

In questo ambiente di lavoro non c'era né un'area di lavoro Databricks né un iPhone. Quindi:

- Di NOOP sono provati con test automatici i **formati dei file CSV** (colonne, virgolette, numeri, elenco delle
  misure ammesse) e le regole del caricamento (indirizzi accettati, percorso nel volume, intestazione, significato
  dei codici di risposta). Le azioni dei Comandi rapidi e il pulsante nelle Impostazioni sono compilati dalla
  CI ma non sono stati eseguiti su un iPhone.
- Il **codice SQL** è scritto dalla documentazione di Databricks. È stato eseguito su un Spark locale con file di
  prova (le stesse istruzioni, sostituendo solo `read_files` e le tabelle Delta con equivalenti locali), ma non su
  Databricks vero.
- Il **comando rapido** (i nomi delle azioni in italiano, le caselle dell'indirizzo, dell'intestazione e del corpo
  della richiesta) è descritto dalla documentazione e dal funzionamento noto di iOS, non provato su un iPhone.
  Se una voce di menu ha un nome leggermente diverso nella tua versione di iOS, cerca quella più simile.
- Non è stata provata nemmeno la Files API con un token di Free Edition: se il primo caricamento dà un errore che
  non è nella tabella qui sopra, il testo dell'errore (visibile se aggiungi "Mostra risultato" dopo "Ottieni
  contenuti dell'URL") dice di solito cosa manca.
