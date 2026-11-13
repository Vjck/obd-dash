import Foundation

/// Short Italian descriptions for the most common diesel trouble codes.
enum DTCInfo {
    static func describe(_ code: String) -> String {
        if let text = known[code] { return text }
        switch code.prefix(2) {
        case "P0", "P2": return "Codice motore standard. Cerca \(code) per i dettagli."
        case "P1", "P3": return "Codice motore specifico Opel. Cerca \(code) Opel Corsa per i dettagli."
        default:
            switch code.prefix(1) {
            case "C": return "Codice del telaio (freni, sterzo, sospensioni)."
            case "B": return "Codice della carrozzeria (airbag, comfort, luci)."
            case "U": return "Codice di comunicazione tra le centraline."
            default: return "Codice non riconosciuto."
            }
        }
    }

    private static let known: [String: String] = [
        "P0087": "Pressione carburante nel rail troppo bassa",
        "P0088": "Pressione carburante nel rail troppo alta",
        "P0100": "Debimetro (sensore massa aria): circuito difettoso",
        "P0101": "Debimetro (sensore massa aria): valore non plausibile",
        "P0105": "Sensore pressione collettore: circuito difettoso",
        "P0110": "Sensore temperatura aria aspirata: circuito difettoso",
        "P0115": "Sensore temperatura liquido: circuito difettoso",
        "P0190": "Sensore pressione rail: circuito difettoso",
        "P0234": "Turbo: sovrapressione",
        "P0299": "Turbo: pressione insufficiente",
        "P0335": "Sensore giri albero motore: circuito difettoso",
        "P0340": "Sensore albero a camme: circuito difettoso",
        "P0380": "Candelette: circuito difettoso",
        "P0400": "Ricircolo gas di scarico (EGR): flusso anomalo",
        "P0401": "Ricircolo gas di scarico (EGR): flusso insufficiente",
        "P0402": "Ricircolo gas di scarico (EGR): flusso eccessivo",
        "P0403": "Valvola EGR: circuito difettoso",
        "P0404": "Valvola EGR: posizione non plausibile",
        "P0420": "Catalizzatore: efficienza sotto la soglia",
        "P0470": "Sensore pressione gas di scarico: circuito difettoso",
        "P0500": "Sensore velocità veicolo: guasto",
        "P0562": "Tensione di sistema bassa",
        "P0563": "Tensione di sistema alta",
        "P0670": "Centralina candelette: circuito difettoso",
        "P2002": "Filtro antiparticolato: efficienza sotto la soglia",
        "P2031": "Sensore temperatura gas di scarico: circuito difettoso",
        "P2032": "Sensore temperatura gas di scarico: segnale basso",
        "P2033": "Sensore temperatura gas di scarico: segnale alto",
        "P2279": "Perdita d'aria nel sistema di aspirazione",
        "P242F": "Filtro antiparticolato: accumulo di ceneri",
        "P2452": "Sensore pressione differenziale FAP: circuito difettoso",
        "P2453": "Sensore pressione differenziale FAP: valore non plausibile",
        "P2458": "Rigenerazione FAP: durata anomala",
        "P2459": "Rigenerazione FAP: troppo frequente",
        "P2463": "Filtro antiparticolato: accumulo eccessivo di fuliggine",
    ]
}
