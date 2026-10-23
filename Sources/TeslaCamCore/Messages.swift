import Foundation

/// Lidské české texty místo chybových kódů.
public enum Messages {
    public static let incomplete = "Klip je nedopsaný, auto ho nahrávalo ve chvíli vytažení flashky. Nejde odemknout."
    public static let locked = "Doplňkový soubor (event.json / thumb.png) je zamčený a Tesla k němu klíč nevydá. Náhled vytvoříme z videa."
    public static let waitingForToken = "Čeká na nový token."

    public static func text(for reason: FailureReason) -> String {
        switch reason {
        case .container(let error): text(for: error)
        case .keyRejected(let code): keyRejected(code)
        case .keyService(let error): text(for: error)
        case .io(let detail): "Chyba při zápisu nebo čtení souboru: \(detail)"
        }
    }

    public static func text(for error: ContainerError) -> String {
        switch error {
        case .notEncrypted: "Soubor není šifrovaný klip Tesly."
        case .truncated: "Soubor je useknutý, chybí mu část hlavičky. Nejspíš se nedokopíroval celý."
        case .metadataMissing: incomplete
        case .invalidVIN, .invalidPublicKey, .invalidSize: "Hlavička souboru je poškozená, nejde z ní poznat, ke kterému autu patří."
        case .invalidKeyLength: "Tesla vrátila klíč v nečekaném formátu."
        case .partialPage, .shortPayload: "Video je kratší, než hlavička slibuje. Soubor se nejspíš nedokopíroval celý, zkopíruj ho znovu."
        case .notMP4: "Klíč k souboru nesedí, po odemčení by vznikl jen šum. Soubor jsme neuložili."
        case .cryptoFailure(let status): "Dešifrování selhalo (kód \(status))."
        }
    }

    public static func text(for error: KeyServiceError) -> String {
        switch error {
        case .unauthorized: "Token vypršel nebo je neplatný. Vlož nový."
        case .httpStatus(429, _): "Tesla server teď odmítá další dotazy (příliš mnoho požadavků). Zkus to za chvíli."
        case .httpStatus(let code, _) where code >= 500: "Tesla server má potíže (chyba \(code)). Zkus to za chvíli."
        case .httpStatus(let code, _): "Tesla server odpověděl neočekávaně (chyba \(code))."
        case .network(let detail): "Nepodařilo se spojit s Tesla serverem: \(detail)"
        case .malformedResponse: "Tesla server vrátil odpověď, které nerozumíme."
        case .responseTooLarge: "Tesla server vrátil podezřele velkou odpověď, ignorujeme ji."
        }
    }

    public static func keyRejected(_ code: String) -> String {
        switch code {
        case "error.unable_to_verify_ownership":
            "Tesla nepotvrdila, že klip patří k tvému účtu (jiné auto, jiný účet, nebo chybí metadata)."
        case "no_key":
            "Tesla k tomuto klipu nevrátila klíč."
        case "malformed_key":
            "Tesla vrátila poškozený klíč."
        default:
            "Tesla odmítla vydat klíč (\(code))."
        }
    }

    public static func remuxFailed(_ error: Error) -> String {
        let detail = (error as? FFmpeg.Failure)?.detail ?? error.localizedDescription
        return "Úprava pro přehrávače (remux) selhala, uložili jsme původní odemčené video. \(detail)"
    }

    public static func text(for outcome: FileOutcome) -> String? {
        switch outcome {
        case .incomplete: incomplete
        case .locked: locked
        case .waitingForToken: waitingForToken
        case .failed(let reason): text(for: reason)
        case .unlocked(_, _, let note): note
        case .copied, .alreadyDone: nil
        }
    }
}
