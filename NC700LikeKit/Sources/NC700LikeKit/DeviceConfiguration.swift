import Foundation

public struct DeviceConfiguration: Codable, Equatable, Sendable {
    public var serviceUUID: String
    public var characteristicUUID: String

    /// FE03(音声受付)サービスとその通知特性。購読しないとボタン押下で
    /// ヘッドホンがエラー音声を出し、主特性の値も変わらないことが実機で確認された。
    public var audioServiceUUID: String
    public var audioCharacteristicUUID: String

    /// FE03 の書き込み用特性。デバッグ用の手動送信(D)で使う。
    public var writeCharacteristicUUID: String

    /// 0始まりのオフセット。観測では値は19バイトで、末尾2バイト(index 17,18)が変化する
    public var stateOffsetInBytes: Int
    public var stateLengthInBytes: Int
    public var pressStates: [[UInt8]]
    public var debounceInterval: TimeInterval

    public var scanNameFragment: String

    public init(
        serviceUUID: String = "FDD2",
        characteristicUUID: String = "7B61AD83-041C-4333-A0AB-EFB2AB7BDD43",
        audioServiceUUID: String = "FE03",
        audioCharacteristicUUID: String = "2BEEA05B-1879-4BB4-8A2F-72641F82420B",
        writeCharacteristicUUID: String = "F04EB177-3005-43A7-AC61-A390DDF83076",
        stateOffsetInBytes: Int = 17,
        stateLengthInBytes: Int = 2,
        pressStates: [[UInt8]] = [[0x00, 0x06], [0x10, 0x0E]],
        debounceInterval: TimeInterval = 0.3,
        scanNameFragment: String = "Bose NC 700"
    ) {
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.audioServiceUUID = audioServiceUUID
        self.audioCharacteristicUUID = audioCharacteristicUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.stateOffsetInBytes = stateOffsetInBytes
        self.stateLengthInBytes = stateLengthInBytes
        self.pressStates = pressStates
        self.debounceInterval = debounceInterval
        self.scanNameFragment = scanNameFragment
    }
}

extension DeviceConfiguration {
    public static let `default` = DeviceConfiguration()

    /// 無効値を含まないJSON設定ファイルを読む。任意デコードキーなので
    /// 部分的な上書きもしやすい。
    ///
    /// JSONは大文字小文字を区別しないキーで:
    /// {
    ///   "serviceUUID": "FDD2",
    ///   "characteristicUUID": "7B61AD83-...",
    ///   "stateOffsetInBytes": 16,
    ///   "stateLengthInBytes": 2,
    ///   "pressStates": [[0, 6], [16, 14]],
    ///   "debounceInterval": 0.3,
    ///   "scanNameFragment": "Bose NC 700"
    /// }
    public static func load(fromJSONData data: Data) -> DeviceConfiguration? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let partial: PartialDeviceConfiguration? = try? decoder.decode(
            PartialDeviceConfiguration.self, from: data
        )
        guard let partial else { return nil }
        var config = DeviceConfiguration.default
        if let v = partial.serviceUUID { config.serviceUUID = v }
        if let v = partial.characteristicUUID { config.characteristicUUID = v }
        if let v = partial.audioServiceUUID { config.audioServiceUUID = v }
        if let v = partial.audioCharacteristicUUID { config.audioCharacteristicUUID = v }
        if let v = partial.writeCharacteristicUUID { config.writeCharacteristicUUID = v }
        if let v = partial.stateOffsetInBytes, v >= 0 { config.stateOffsetInBytes = v }
        if let v = partial.stateLengthInBytes, v > 0 { config.stateLengthInBytes = v }
        if let v = partial.pressStates {
            let normalized = v.map { $0.map { UInt8(truncatingIfNeeded: max(0, $0)) } }
                .filter { $0.count == config.stateLengthInBytes }
            if !normalized.isEmpty { config.pressStates = normalized }
        }
        if let v = partial.debounceInterval, v >= 0 { config.debounceInterval = v }
        if let v = partial.scanNameFragment { config.scanNameFragment = v }
        return config
    }

    public static func load(fromBundle bundle: Bundle = .main) -> DeviceConfiguration {
        guard let url = bundle.url(forResource: "NC700LikeConfiguration", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return .default }
        return load(fromJSONData: data) ?? .default
    }
}

public struct PartialDeviceConfiguration: Codable, Sendable {
    public var serviceUUID: String?
    public var characteristicUUID: String?
    public var audioServiceUUID: String?
    public var audioCharacteristicUUID: String?
    public var writeCharacteristicUUID: String?
    public var stateOffsetInBytes: Int?
    public var stateLengthInBytes: Int?
    public var pressStates: [[Int]]?
    public var debounceInterval: TimeInterval?
    public var scanNameFragment: String?
}
