# Dashboard e Genie per i dati NOOP

Questa guida costruisce a mano, in Databricks, una dashboard "AI/BI" con cinque pagine (Sonno, Recupero, Forma,
Forza, Condizionamento) e uno spazio Genie per fare domande in italiano. Parte dal presupposto che tu abbia già
seguito il [README](README.md) fino al punto 6: le tabelle e le viste in `noop_uploads.noop` esistono e hanno
dei dati.

NOOP non è un dispositivo medico. Questi grafici sono per curiosità personale sul tuo allenamento e sul tuo
sonno, non per prendere decisioni di salute.

Se il tuo catalogo non si chiama `noop_uploads`, sostituisci il nome in tutte le query qui sotto.

## Come si crea la dashboard

1. Nel menu a sinistra di Databricks apri **Dashboards** e premi **Create dashboard**. Dai un nome, per esempio
   `NOOP`.
2. Nella scheda **Data** premi **Create from SQL** e crea un dataset per ogni riga della colonna "Dataset" qui
   sotto (puoi riusare lo stesso dataset in più grafici). Dai al dataset il nome indicato in tabella.
3. Nella scheda **Canvas** crea una pagina per ogni sezione (**+ Add page**, in alto) e aggiungi i grafici con
   **Add a visualization**: scegli il dataset, il tipo di grafico, poi riempi gli assi come indicato.
4. Aggiungi in alto a ogni pagina un filtro **Date range picker** sul campo `day` (o `week_start`) e, nella pagina
   Forza, un filtro **Single select** o **Multiple select** sul campo `lift`.
5. Premi **Publish**. La dashboard si apre con il magazzino SQL (SQL warehouse) di Free Edition: la prima apertura
   può metterci una trentina di secondi per accenderlo.

## I dataset

Dai a ogni dataset il nome della prima colonna. Tutte le query sono brevi apposta.

| Nome dataset | Query |
|---|---|
| `notti` | `SELECT day, total_sleep_min / 60 AS ore, sleep_efficiency, deep_min, rem_min, light_min, rest FROM noop_uploads.noop.days WHERE total_sleep_min IS NOT NULL ORDER BY day` |
| `sonno_settimane` | `SELECT * FROM noop_uploads.noop.sleep_weekly ORDER BY week_start` |
| `recupero` | `SELECT * FROM noop_uploads.noop.recovery_daily ORDER BY day` |
| `vo2max` | `SELECT * FROM noop_uploads.noop.vo2max ORDER BY day` |
| `alzate` | `SELECT * FROM noop_uploads.noop.lift_progress ORDER BY week_start` |
| `zone` | `SELECT * FROM noop_uploads.noop.zones_weekly ORDER BY week_start` |
| `allenamenti` | `SELECT start_local, sport, duration_min, avg_hr, max_hr, kcal, strain, z1_min, z2_min, z3_min, z4_min, z5_min FROM noop_uploads.noop.workouts ORDER BY start_local DESC LIMIT 30` |

## I grafici (12, più una tabella)

| # | Pagina | Titolo | Dataset | Tipo | Asse X | Asse Y | Colore / serie |
|---|---|---|---|---|---|---|---|
| 1 | Sonno | Ore dormite per notte | `notti` | Linea | `day` (giorno) | `ore` (media) | nessuno |
| 2 | Sonno | Fasi del sonno | `notti` | Barre impilate | `day` (giorno) | `deep_min`, `rem_min`, `light_min` (somma) | una serie per fase: profondo, REM, leggero |
| 3 | Sonno | Rest e efficienza | `notti` | Linea (due assi) | `day` (giorno) | `rest` (asse sinistro), `sleep_efficiency` (asse destro) | una serie per misura |
| 4 | Sonno | Media settimanale | `sonno_settimane` | Barre | `week_start` (settimana) | `avg_sleep_h` (media) | nessuno |
| 5 | Recupero | Charge e media a 7 giorni | `recupero` | Linea | `day` (giorno) | `charge`, `charge_7d` | una serie per misura |
| 6 | Recupero | HRV e battito a riposo | `recupero` | Linea (due assi) | `day` (giorno) | `hrv_7d` (asse sinistro), `resting_hr_7d` (asse destro) | una serie per misura |
| 7 | Forma | VO2max | `vo2max` | Linea con punti | `day` (giorno) | `vo2max_est`, `vo2max_exercise` | una serie per stima |
| 8 | Forza | Carico massimo per alzata | `alzate` | Linea con punti | `week_start` (settimana) | `max_weight_kg` (massimo) | colore = `lift` |
| 9 | Forza | 1RM stimato | `alzate` | Linea con punti | `week_start` (settimana) | `max_est_1rm_kg` (massimo) | colore = `lift` |
| 10 | Forza | Volume settimanale | `alzate` | Barre impilate | `week_start` (settimana) | `volume_kg` (somma) | colore = `lift` |
| 11 | Condizionamento | Minuti per zona cardiaca | `zone` | Barre impilate | `week_start` (settimana) | `z1_min` ... `z5_min` (somma) | una serie per zona (dal blu al rosso) |
| 12 | Condizionamento | Effort giornaliero | `recupero` | Barre | `day` (giorno) | `effort` (media) | nessuno |

Un tredicesimo elemento utile è la tabella degli ultimi allenamenti: pagina Condizionamento, tipo **Table**, dataset
`allenamenti`, tutte le colonne.

Note sui grafici:

- **Rest, Charge, Effort** sono i tre punteggi di NOOP, tutti da 0 a 100. `rest` è il punteggio del sonno. Charge
  e Effort sono stime calcolate sul telefono: non sono i numeri di WHOOP.
- **1RM stimato** (grafico 9) è una stima con la formula di Epley, `carico x (1 + ripetizioni / 30)`, calcolata solo
  per serie da 1 a 10 ripetizioni. Con 1 ripetizione la formula dà circa il 3 per cento in più del carico
  sollevato: è una stima, non un record. Il carico massimo vero è nel grafico 8.
- **Volume** (grafico 10) è serie x ripetizioni x carico quando lo schema è del tipo `5x5`, altrimenti ripetizioni x
  carico.
- **Zone** (grafico 11): i minuti si calcolano dalla frequenza cardiaca della fascia, con la tua frequenza
  massima come base per le zone. Un allenamento senza battito registrato non compare; un WOD compare solo se hai
  indicato inizio e fine dell'intera sessione. Un allenamento della fascia che si sovrappone a un WOD con zone
  conta una volta sola (vince il WOD).
- Le settimane iniziano di lunedì.

## Domande per Genie

Genie è l'assistente che risponde a domande in linguaggio naturale scrivendo la query SQL al posto tuo. Sono
domande di esempio, da adattare:

1. Come è cambiato il mio massimale stimato di back squat negli ultimi 3 mesi?
2. In quali settimane ho passato più minuti nelle zone 4 e 5?
3. Quante ore ho dormito in media ogni settimana nell'ultimo mese, e in quale settimana ho dormito meno?
4. Com'è il mio HRV medio nei giorni dopo un allenamento con Effort sopra 70, rispetto agli altri giorni?
5. Qual è stato il mio miglior risultato in ogni WOD con carico (peso massimo e data)?
6. Come si è mosso il mio VO2max dall'inizio dell'anno?

### Come si crea lo spazio Genie

1. Nel menu a sinistra apri **Genie** e premi **New**.
2. Quando chiede i dati, scegli il catalogo `noop_uploads`, lo schema `noop` e seleziona queste tabelle e viste:
   `days`, `sleeps`, `workouts`, `wods`, `wod_movements`, `metrics`, `lifts`, `lift_progress`, `zones_weekly`,
   `sleep_weekly`, `recovery_daily`, `vo2max` (e `glucose_daily` se carichi la glicemia). Non selezionare
   `lift_alias`.
3. Scegli il magazzino SQL (è l'unico che Free Edition ti dà) e salva con un nome, per esempio `NOOP`.
4. Apri **Instructions** e incolla delle istruzioni generali, che aiutano molto Genie a non sbagliare:

   ```text
   Rispondi in italiano. I dati sono sport e sonno di una sola persona, esportati da NOOP.
   Charge, Effort e Rest sono punteggi da 0 a 100 calcolati da NOOP (Charge = recupero, Effort = sforzo,
   Rest = qualità del sonno). Le colonne con suffisso _min sono minuti, _kg sono chilogrammi.
   Le settimane iniziano di lunedì. Per i massimali usa la tabella lift_progress o la vista lifts
   (colonna est_1rm_kg, stima di Epley). Per le zone di frequenza cardiaca usa zones_weekly.
   Non dare consigli medici né dosi di niente: descrivi soltanto i numeri.
   ```
5. Prova le domande qui sopra. Se una risposta è sbagliata, correggila con **Add as instruction** o salva la query
   giusta come esempio: Genie la riusa la volta dopo.

Se Genie risponde in modo strano, controlla sempre la query SQL che mostra sotto la risposta: è la verità, il
testo sopra è solo il suo riassunto.
