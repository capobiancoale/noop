# NOOP su TestFlight dal browser (senza Mac, senza Xcode)

Questa branch (`claude-automatic-build`) compila NOOP su **GitHub Actions** (runner macOS di GitHub) e lo
carica su **TestFlight**. Tu avvii tutto dal browser; l'app si installa su iPhone e Apple Watch con l'app
TestFlight. È lo stesso meccanismo del "Loop browser build" (LoopKit/LoopWorkspace), adattato a NOOP.

- **Costi GitHub:** zero — il repository è pubblico, i minuti macOS di Actions sono gratuiti.
- **Costi Apple:** serve l'**Apple Developer Program a pagamento** (99 €/anno). Senza, TestFlight non esiste.
- **Tempo:** la prima configurazione ~30–45 minuti, una volta sola. Ogni build poi ~25–40 minuti, da sola.

I tuoi identificativi saranno namespaced con il tuo Team ID, così non possono collidere con nessun altro:

| Target | Bundle ID |
|---|---|
| App iPhone | `com.<TEAMID>.noopapp.noop` |
| Widget / Live Activity | `com.<TEAMID>.noopapp.noop.widgets` |
| App Apple Watch | `com.<TEAMID>.noopapp.noop.watch` |
| Complicazione Watch | `com.<TEAMID>.noopapp.noop.watch.complications` |
| App Group | `group.com.<TEAMID>.noopapp.noop` |

`<TEAMID>` = il tuo Team ID Apple di 10 caratteri (es. `AB12CD34EF`).

---

## Configurazione (una volta sola)

### 1. Abilita GitHub Actions sul fork ⚠️
`capobiancoale/noop` è un **fork**: GitHub tiene spenti i workflow dei fork finché non li accendi tu.
Apri <https://github.com/capobiancoale/noop/actions> → **"I understand my workflows, go ahead and enable them"**.

> È uno dei motivi più comuni per cui il "Loop automatic build" non parte: sui fork Actions e le
> esecuzioni programmate sono disattivate di default.

### 1b. Rendi `claude-automatic-build` la branch di default ⚠️ (obbligatorio)
<https://github.com/capobiancoale/noop/settings> → sezione **Default branch** → icona ⇄ → scegli
`claude-automatic-build` → **Update** → conferma.

Perché serve: GitHub mostra il pulsante **Run workflow** solo per i workflow presenti nella branch di
default, e fa partire le build **mensili** programmate solo da lì. Con `main` come default non vedresti
i pulsanti dei workflow 1–4. (Alternativa: chiedi a Claude di copiare i quattro workflow anche in `main`;
poi nel menu "Run workflow" scegli la branch `claude-automatic-build`.)

### 2. Team ID → secret `TEAMID`
<https://developer.apple.com/account> → **Membership details** → **Team ID** (10 caratteri, maiuscole e numeri).

### 3. Nuova chiave API di App Store Connect → `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY`
1. <https://appstoreconnect.apple.com/access/integrations/api> → scheda **Team Keys** → **+**.
2. Nome `NOOP Fastlane`, accesso **Admin** → **Generate**.
3. Copia il **Key ID** (10 caratteri) → `FASTLANE_KEY_ID`.
4. Copia l'**Issuer ID** (in alto, formato `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) → `FASTLANE_ISSUER_ID`.
5. **Download API Key** → file `AuthKey_XXXXXXXXXX.p8` (si scarica **una volta sola**, conservalo).
   Aprilo con un editor di testo e copia **tutto** il contenuto, righe `-----BEGIN PRIVATE KEY-----` e
   `-----END PRIVATE KEY-----` comprese → `FASTLANE_KEY`.

### 4. Token GitHub → secret `GH_PAT`
<https://github.com/settings/tokens> → **Generate new token (classic)**:
- Note: `NOOP Fastlane`
- Expiration: **No expiration** (consigliato per le build automatiche; se metti una scadenza, segnati
  in calendario di rinnovarlo e aggiornare il secret)
- Scope: spunta **`repo`** (basta questo)

Copia il token (`ghp_…`) → `GH_PAT`. Serve a leggere/scrivere il repository privato dei certificati.

### 5. Password dei certificati → secret `MATCH_PASSWORD`
Inventa una password robusta e **salvala nel tuo password manager**. Cifra certificato e profili dentro
il repository privato `NOOP-Match-Secrets` (lo crea da solo il workflow al primo avvio). Se la perdi,
dovrai svuotare quel repository e ricreare i certificati.

### 6. Inserisci i 6 secret nel repository
<https://github.com/capobiancoale/noop/settings/secrets/actions> → **New repository secret**, sei volte,
con questi nomi **esatti**:

| Secret | Valore |
|---|---|
| `TEAMID` | passo 2 |
| `FASTLANE_KEY_ID` | passo 3 |
| `FASTLANE_ISSUER_ID` | passo 3 |
| `FASTLANE_KEY` | passo 3 (contenuto del .p8) |
| `GH_PAT` | passo 4 |
| `MATCH_PASSWORD` | passo 5 |

**Variabili facoltative** (stessa pagina → scheda **Variables**):

| Variabile | Effetto |
|---|---|
| `ENABLE_NUKE_CERTS` = `true` | Quando il certificato di distribuzione scade (una volta l'anno) lo rinnova da solo. Consigliato. |
| `AUTO_BUILD_ON_PUSH` = `false` | Disattiva le build automatiche a ogni push (restano quelle a mano). |
| `MATCH_REPO` = `Match-Secrets` | Usa il repository dei certificati di **Loop** invece di uno separato — in quel caso `MATCH_PASSWORD` deve essere quella di Loop. |

### 7. Workflow "1. Validate Secrets" e "2. Add Identifiers"
Tab **Actions** → a sinistra **1. Validate Secrets** → **Run workflow** (branch `claude-automatic-build`)
→ deve diventare verde ✅. Poi **2. Add Identifiers** → **Run workflow** → verde ✅.

Poi il **passaggio manuale** (l'API di Apple non permette di farlo in automatico):
1. <https://developer.apple.com/account/resources/identifiers/list/applicationGroup> → **+** →
   **App Groups** → Description `NOOP`, Identifier `group.com.<TEAMID>.noopapp.noop` → **Register**.
2. Torna alla lista, filtro **App IDs**. Per **ognuno dei quattro** identificativi NOOP
   (`…noopapp.noop`, `….widgets`, `….watch`, `….watch.complications`): aprilo → **App Groups** →
   **Configure** → spunta `group.com.<TEAMID>.noopapp.noop` → **Continue** → **Save**.

### 8. Crea l'app su App Store Connect
<https://appstoreconnect.apple.com/apps> → **+** → **New App**:
- Platforms: **iOS**
- Name: deve essere unico su tutto l'App Store, quindi ad es. `NOOP Ale` (è solo il nome su App Store
  Connect/TestFlight: sotto l'icona dell'iPhone resta **NOOP**)
- Primary language: Italiano
- Bundle ID: **`com.<TEAMID>.noopapp.noop`**
- SKU: ad es. `noop-ale`
- User Access: Full Access → **Create**

### 9. Workflow "3. Create Certificates"
**Actions** → **3. Create Certificates** → **Run workflow** → verde ✅.

### 10. La prima build: "4. Build NOOP"
**Actions** → **4. Build NOOP** → **Run workflow** (branch `claude-automatic-build`). ~25–40 minuti.
Quando è verde, Apple elabora la build per altri ~5–20 minuti.

### 11. Installa con TestFlight
1. App Store Connect → la tua app → **TestFlight** → **Internal Testing** → **+** → gruppo `Io` →
   aggiungi te stesso → attiva **Automatic Distribution** (così ogni nuova build ti arriva da sola).
2. Sull'iPhone installa **TestFlight** dall'App Store, apri l'invito (email) → **Install**.
3. Apple Watch: app **Watch** sull'iPhone → **App disponibili** → NOOP → **Installa** (o attiva
   l'installazione automatica delle app).

La domanda sulla crittografia ("Missing Compliance") non comparirà: è già dichiarata nel progetto
(`ITSAppUsesNonExemptEncryption = NO`, NOOP usa solo l'HTTPS di sistema).

---

## Build automatiche

- **A ogni push** su `claude-automatic-build` che cambia l'app (sorgenti, pacchetti, `project.yml`,
  fastlane) parte da sola una nuova build → ti arriva su TestFlight. Più push ravvicinati si mettono in
  coda (vince l'ultimo), mai due build insieme. Spegnibile con `AUTO_BUILD_ON_PUSH = false`.
- **Una volta al mese** (il 1°), per avere sempre una build fresca — le build TestFlight scadono dopo
  **90 giorni**. Funziona perché al passo 1b `claude-automatic-build` è diventata la branch di default
  (GitHub esegue gli orari programmati solo da lì).
- Finché i secret non sono configurati, le build automatiche vengono **saltate in silenzio** (niente ❌).

**Per portare su TestFlight nuove funzioni:** vanno unite in questa branch — chiedi a Claude di farlo.

---

## Se qualcosa va storto

| Messaggio / sintomo | Soluzione |
|---|---|
| I workflow non compaiono o non partono | Passo 1: abilita Actions sul fork. |
| Non c'è il pulsante **Run workflow** / mancano i workflow 1–3 | Passo 1b: `claude-automatic-build` deve essere la branch di default. |
| `The GH_PAT secret …` | Rigenera il token classic con scope `repo` (passo 4) e aggiorna il secret. |
| `Unable to decrypt … MATCH_PASSWORD` | La password non è quella che ha cifrato il repository dei certificati. Rimetti quella giusta, oppure svuota `NOOP-Match-Secrets` e rilancia il passo 9. |
| `Accept the latest Apple Developer Program License Agreement` | Accettalo su <https://developer.apple.com/account>, aspetta qualche minuto, riprova. |
| `The App Group … is not enabled on: …` | Passo 7 (parte manuale). Poi rilancia il passo 9. Se persiste: developer.apple.com → **Profiles** → elimina i 4 profili `match AppStore com.<TEAMID>.noopapp…` → passo 9 → passo 10. |
| `Could not read TestFlight builds for …` | Manca l'app su App Store Connect (passo 8), o il Bundle ID scelto è diverso. |
| `maximum number of certificates` | Il team ha già troppi certificati di distribuzione (es. quello di Loop). O usi quello di Loop (`MATCH_REPO = Match-Secrets` + `MATCH_PASSWORD` di Loop), oppure revochi un certificato inutilizzato in developer.apple.com → Certificates. |
| Errore di compilazione Swift | Scarica l'artifact **build-log** dalla pagina della run e passalo a Claude. |
| La build mensile non parte | Passo 1b: serve che questa sia la branch di default. |
| Dopo un rinnovo automatico, Loop non builda più | Normale se Loop usa lo stesso team: lancia una volta "3. Create Certificates" di Loop. |

---

## Come funziona (per chi mantiene il codice)

- `fastlane/Fastfile`, lane `build_noop`: legge l'ultimo numero di build su TestFlight e usa quello +1;
  genera `Strand.xcodeproj` con XcodeGen da una **copia temporanea** di `project.yml` (`project.ci.yml`)
  in cui imposta `NOOP_BUNDLE_PREFIX = com.<TEAMID>.noopapp`, `DEVELOPMENT_TEAM` e
  `CURRENT_PROJECT_VERSION` (`project.yml` non viene mai modificato); scarica certificato + profili con
  match; controlla che ogni profilo contenga l'App Group; firma i 4 target e archivia lo schema `NOOPiOS`.
  La lane `release` carica `NOOP.ipa` su TestFlight.
- `project.yml`: un'unica impostazione, `NOOP_BUNDLE_PREFIX` (default `com.noopapp`), deriva bundle ID
  di app, widget, watch e complicazione, l'ID companion del Watch e l'App Group. Con il default le build
  locali/CI esistenti restano identiche a prima.
- Workflow in `.github/workflows/`: `noop_validate_secrets.yml` (1), `noop_add_identifiers.yml` (2),
  `noop_create_certs.yml` (3), `noop_build.yml` (4). La build usa Xcode 26: App Store Connect accetta
  solo build fatte con l'SDK corrente.
