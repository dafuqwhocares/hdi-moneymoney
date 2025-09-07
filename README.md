# HDI Lebensversicherung Extension for MoneyMoney

Diese Web Banking Extension ermöglicht den Zugriff auf Depotbestände der HDI Versicherungs- oder Investmentpolicen in MoneyMoney.

## Funktionen

- **Login mit Okta-Authentifizierung:**  
   Login über das HDI-Okta-System mit SAML-SSO, wie beim manuellen Zugriff.

- **Depotbestände abrufen:**  
  Alle verfügbaren Fonds-Positionen werden per Web Scraping abgerufen – inklusive aktueller Kurswerte und Stückzahlen (werden nicht im GUI ausgegeben).

- **Flexible Kursabfrage:**  
  Aktuelle Kurse können wahlweise über die HDI-Website oder die justETF-API abgerufen werden:
  - **HDI-Webscraping:** Verwendet die auf der HDI-Seite angezeigten Werte (Kursdatum ist Zeitpunkt der letzten Transaktion).
  - **justETF-API:** Lädt den aktuellen Kurs für ETFs über die justETF-API.

## Aktuelle Einschränkungen

- **Keine Gewinn-/Verlust-Anzeige:**  
  Da HDI keine historischen Transaktionsdaten bereitstellt, können keine Kaufkurse und damit keine Gewinne/Verluste angezeigt werden.

- **Keine Stückzahl-Anzeige:**  
  Obwohl Stückzahlen von der HDI-Website abrufbar sind, werden sie in MoneyMoney nicht angezeigt, da sonst ein Kurswert berechnet wird, der nicht dem tatsächlichen Kaufwert entspricht.

## Konfiguration

### API-Modus umschalten

In der Extension `HDI.lua` kann der Modus für die Kursabfrage geändert werden:

```lua
-- Konfiguration: Wenn true, werden aktuelle Kurse und die Positionsbeträge
-- aus der API (justETF) berechnet: amount = price * quantity; sonst werden
-- die Werte aus dem Webscraping (HDI-Seite) verwendet.
local USE_API = false
```

- **`USE_API = false`** (Standard): Verwendet die Werte von der HDI-Website
- **`USE_API = true`**: Verwendet aktuelle Kurse von justETF und berechnet die einzelnen Fondsbeträge und Gesamtbeträge des Depots neu

## Installation und Nutzung

### Betaversion installieren

Diese Extension funktioniert ausschließlich mit Beta-Versionen von MoneyMoney. Eine signierte Version kann auf der offiziellen Website heruntergeladen werden: https://moneymoney.app/extensions/

### Installation

1. **Öffne MoneyMoney** und gehe zu den Einstellungen (Cmd + ,).
2. Gehe in den Reiter **Extensions** und deaktiviere den Haken bei **"Verify digital signatures of extensions"**.
3. Wähle im Menü **Help > Show Database in Finder**.
4. Kopiere die Datei `HDI.lua` aus diesem Repository in den Extensions-Ordner:
   `~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions`
5. In MoneyMoney sollte nun beim Hinzufügen eines neuen Kontos der Service-Typ **HDI Lebensversicherung** erscheinen.

### Anmeldung

- **Benutzername:**  E-Mail-Adresse (die für HDI verwendet wird)
- **Passwort:** HDI-Passwort

Die Extension führt automatisch die Okta-Authentifizierung durch und folgt den SAML-Redirects.

## Technische Details

### Web Scraping

Die Extension parst die HDI-Website und extrahiert:
- Fondsnamen und ISINs
- Stückzahlen (Anteile)
- Fondsguthaben (Gesamtwert)
- Rücknahmepreise
- Kursdaten

### justETF-API Integration

Bei aktiviertem API-Modus:
- Lädt aktuelle Kurse für ETFs über `https://www.justetf.com/api/`
- Verwendet die ISIN zur Identifikation
- Berechnet Positionsbeträge neu: `amount = currentPrice * quantity`

## Lizenz

Diese Software wird unter der **MIT License mit dem Commons Clause Zusatz** bereitgestellt.  
Das bedeutet, dass Änderungen und Weiterverteilungen (auch modifizierte Versionen) erlaubt sind – eine kommerzielle Nutzung bzw. der Verkauf der Software oder abgeleiteter Werke ist jedoch ohne die ausdrückliche Zustimmung des Autors untersagt.
