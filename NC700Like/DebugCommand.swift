import Foundation

/// デバッグ用の自動送信モード(D-4)。
enum AutoSendMode: String, CaseIterable, Identifiable {
    case off = "オフ"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"
    case p3ThenP1 = "P3の次にP1"

    var id: String { rawValue }
}

/// 未検証の仮説プリセット(D-3)。
enum DebugPreset: String, CaseIterable, Identifiable {
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"

    var id: String { rawValue }

    var template: String {
        switch self {
        case .p1: return "10 00 08 08 0D 6A 04 0A 02 08 {ID}"
        case .p2: return "10 00 0A 08 0C 62 06 08 00 12 02 08 {ID}"
        case .p3: return "10 00 04 08 0B 4A 00"
        }
    }
}

enum HexTool {
    /// "{ID}" を idByte(直近に受信した制御パケットの末尾1バイト)に置換して Data 化する。
    /// 空白区切りと連続16進の両表記を許す。解析できないときは nil。
    static func parse(_ template: String, idByte: UInt8?) -> Data? {
        let tokens = template.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .map(String.init)
        var bytes: [UInt8] = []
        for token in tokens {
            if token == "{ID}" {
                guard let idByte else { return nil }
                bytes.append(idByte)
                continue
            }
            guard !token.isEmpty,
                  token.allSatisfy({ $0.isHexDigit }),
                  token.count % 2 == 0
            else { return nil }
            var index = token.startIndex
            while index < token.endIndex {
                let next = token.index(index, offsetBy: 2)
                guard let value = UInt8(token[index..<next], radix: 16) else { return nil }
                bytes.append(value)
                index = next
            }
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }
}
