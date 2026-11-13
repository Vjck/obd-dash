# OBD Dash

App iOS personale (stile Sidecar) che legge i dati della centralina tramite un lettore OBD II ELM327 Bluetooth LE.

- Auto di riferimento: Opel Corsa 2018 1.3 CDTI
- Scritta in SwiftUI, compilata nel cloud con GitHub Actions (nessun Mac necessario)
- Installata sull'iPhone con Sideloadly e un Apple ID gratuito

## Stato

**v0.3:** nuova grafica (stile Apple, accento rosso) e quattro sezioni.

- **Cruscotto:** auto al centro, tachimetro ad arco con giri, riquadri a scelta (consumo istantaneo e medio, turbo, liquido, batteria, FAP, autonomia, temperatura esterna, carico motore, aria aspirata, livello carburante).
- **FAP:** temperature e pressione differenziale se la centralina le fornisce, rilevamento e storico delle rigenerazioni.
- **Viaggi:** distanza, durata, consumo e velocità massima di ogni viaggio.
- **Errori:** lettura e cancellazione dei codici, stato della spia motore.
- **Impostazioni:** scelta e ordine dei dati, serbatoio, correzione dei consumi, log del lettore, modalità dimostrativa.

**v0.4:** ricerca dei dati specifici della centralina (Impostazioni > Ricerca dati FAP) e log completo della fase di collegamento.

Prossimi passi: dati FAP specifici Opel, Live Activity su CarPlay.

## Come ottenere l'app

1. Ogni push su `main` avvia la build. Vai nella scheda **Actions** del repository e apri l'ultima esecuzione verde.
2. In fondo alla pagina, sotto **Artifacts**, scarica `ObdDash-ipa` (è uno zip: estrai `ObdDash.ipa`).
3. Installala con Sideloadly (vedi sotto).

## Installare con Sideloadly (Windows)

1. Installa **iTunes** e **iCloud** scaricati dal sito Apple (non dal Microsoft Store), poi **Sideloadly** da sideloadly.io.
2. Collega l'iPhone al PC con il cavo e conferma "Autorizza questo computer".
3. Apri Sideloadly, trascina `ObdDash.ipa`, inserisci il tuo Apple ID e premi **Start**.
4. Sull'iPhone: Impostazioni > Generali > VPN e gestione dispositivi > autorizza il tuo Apple ID.
5. La prima volta attiva anche la **Modalità sviluppatore**: Impostazioni > Privacy e sicurezza > Modalità sviluppatore, poi riavvia.

Con un Apple ID gratuito l'app scade dopo 7 giorni: basta ripetere il punto 3.

## Struttura

- `project.yml`: definizione del progetto per XcodeGen (il `.xcodeproj` viene generato in CI)
- `Sources/`: codice SwiftUI (`OBDManager` parla con il lettore, `AppStore` salva impostazioni e storico, il resto sono le schermate)
- `.github/workflows/build.yml`: build non firmata e creazione del file `.ipa`
