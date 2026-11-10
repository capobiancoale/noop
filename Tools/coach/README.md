# Coach di NOOP con Ollama sul Mac

Il Coach può usare un modello che gira sul tuo Mac invece di un servizio a pagamento. È gratuito, non
serve nessuna chiave e le domande e le tue metriche restano in casa, tra iPhone e Mac.

## 1. Sul Mac: una riga nel Terminale

Apri **Terminale** (Spotlight → "Terminale") e incolla:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/capobiancoale/noop/refs/heads/claude/blissful-mayer-0dvnwt/Tools/coach/setup_ollama_mac.sh)"
```

Lo script ([setup_ollama_mac.sh](setup_ollama_mac.sh)):
1. installa Ollama in Applicazioni se manca (circa 230 MB da scaricare);
2. lo rende raggiungibile dagli altri dispositivi della rete Wi-Fi, anche dopo un riavvio del Mac;
3. scarica il modello `llama3.2:3b` (circa 2 GB, parla italiano) e crea `noop-coach`, lo stesso
   modello con una finestra di contesto di 8192 token, così le metriche che il Coach manda ci stanno
   (non occupa spazio in più);
4. prova il modello e stampa l'indirizzo da scrivere sull'iPhone.

Si può rilanciare quando vuoi: rifà solo quello che manca.

Spazio totale sul Mac: circa 2,5 GB. Per un modello ancora più piccolo (1,3 GB, risposte più semplici):

```bash
NOOP_COACH_MODEL=llama3.2:1b bash -c "$(curl -fsSL https://raw.githubusercontent.com/capobiancoale/noop/refs/heads/claude/blissful-mayer-0dvnwt/Tools/coach/setup_ollama_mac.sh)"
```

## 2. Sull'iPhone: NOOP → Coach

| Campo | Valore |
|---|---|
| Provider | **Personalizzato** |
| URL del server | quello stampato dallo script, per esempio `http://MacBook-di-Alessio.local:11434/v1` |
| Modello | `noop-coach` (tocca **Aggiorna modelli**; se non compare, **Personalizzato…** e scrivi `noop-coach`) |
| Chiave API (opzionale) | lascia vuoto |

Tocca **Collega**. La prima volta iOS chiede se NOOP può trovare dispositivi sulla rete locale: tocca
**Consenti**. Se hai detto di no: Impostazioni → Privacy e sicurezza → Rete locale → NOOP.

## Da sapere

- **Il Mac deve essere acceso, sveglio e sulla stessa Wi-Fi dell'iPhone.** Se dorme, il Coach dà errore
  di rete. Se è un portatile, in Impostazioni di Sistema → Batteria → Opzioni puoi attivare l'opzione
  che impedisce lo stop automatico con l'alimentatore collegato e il monitor spento.
- **Qualità.** Un modello da 3 miliardi di parametri è molto più piccolo dei modelli cloud: va bene per
  domande semplici su sonno, recovery e allenamenti, ma può sbagliare nel leggere i numeri. Ricontrolla
  sempre i dati nell'app. Su un Mac Apple Silicon risponde in pochi secondi, su un Mac Intel è lento.
- **Rete.** Chiunque sia sulla stessa rete può usare Ollama (non serve una password). A casa va bene;
  su una Wi-Fi pubblica chiudi Ollama (icona nella barra dei menu → Quit).
- **Fuori casa.** Funziona solo sulla rete del Mac. Per usarlo anche fuori serve una VPN personale come
  Tailscale (gratuita per uso personale) su Mac e iPhone, con l'indirizzo `http://100.x.y.z:11434/v1`
  che Tailscale assegna al Mac. Questa strada con NOOP non è ancora stata provata.

## Togliere tutto

Chiudi Ollama (icona nella barra dei menu → Quit), poi nel Terminale:

```bash
rm -rf ~/.ollama                                   # i modelli scaricati
rm ~/Library/LaunchAgents/com.noop.ollama-host.plist
launchctl unsetenv OLLAMA_HOST
```

e trascina Ollama.app dal Finder nel Cestino.
