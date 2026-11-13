import Foundation

/// USB identity of FlySky transmitters, from `Product_ID_List._Sendor.csv`
/// shipped with FlySky Assistant, plus the model-compatibility groups from
/// `ModelInPut.txt`.
public enum Products {
    public static let vendorID: UInt16 = 0x284E
    /// FlySky's Windows firmware updaters accept a transmitter under this vendor
    /// ID as well (same product ID). Not yet observed on real hardware.
    public static let bootloaderVendorID: UInt16 = 0x9243

    public struct Product: Sendable, Equatable {
        public let productID: UInt16
        public let name: String
        public let family: Family
    }

    public enum Family: String, Sendable {
        case noble      // NB4 / NB4 Pro / Noble plus / Noble Pro plus
        case pl18
        case pl18ev
        case g11p
        case st16
        case other
    }

    public static let all: [Product] = [
        .init(productID: 0x8D00, name: "NB4", family: .noble),
        .init(productID: 0x8D02, name: "NB4 Lite", family: .noble),
        .init(productID: 0x8D03, name: "NB4 Pro", family: .noble),
        .init(productID: 0x8D04, name: "NB4 EDU", family: .noble),
        .init(productID: 0x8D05, name: "NB4 Pro CN", family: .noble),
        .init(productID: 0x8D06, name: "NB4 Pro EN", family: .noble),
        .init(productID: 0x8D07, name: "NB4 Pro EU", family: .noble),
        .init(productID: 0x8D08, name: "Noble plus CN", family: .noble),
        .init(productID: 0x8D09, name: "Noble plus EN", family: .noble),
        .init(productID: 0x8D0A, name: "Noble plus EU", family: .noble),
        .init(productID: 0x8D0B, name: "Noble Pro plus CN", family: .noble),
        .init(productID: 0x8D0C, name: "Noble Pro plus EN", family: .noble),
        .init(productID: 0x8D0D, name: "Noble Pro plus EU", family: .noble),
        .init(productID: 0x8D0F, name: "Noble plus TW", family: .noble),
        .init(productID: 0x8D10, name: "Noble plus JP", family: .noble),
        .init(productID: 0x8D11, name: "Noble plus DE", family: .noble),
        .init(productID: 0x8D12, name: "Noble Pro plus JP", family: .noble),
        .init(productID: 0x8E00, name: "PL18", family: .pl18),
        .init(productID: 0x8E01, name: "PL18 EV", family: .pl18ev),
        .init(productID: 0x8E02, name: "PL18 Lite", family: .pl18),
        .init(productID: 0x8E03, name: "PL18 EDU", family: .pl18),
        .init(productID: 0x8E04, name: "PL18 EV Lite", family: .pl18ev),
        .init(productID: 0x8E05, name: "PL18 EV DE", family: .pl18ev),
        .init(productID: 0x8E06, name: "PL18 Ultra", family: .other),
        .init(productID: 0x8041, name: "FS-G7P", family: .other),
        .init(productID: 0x8050, name: "FS-KM-G7P", family: .other),
        .init(productID: 0x8051, name: "FS-G7P plus", family: .other),
        .init(productID: 0x8052, name: "FS-KM-G7P plus", family: .other),
        .init(productID: 0x8E80, name: "FS-ST8", family: .other),
        .init(productID: 0x8E81, name: "FS-ST8B", family: .other),
        .init(productID: 0x8E90, name: "EX8", family: .other),
        .init(productID: 0x8EA0, name: "FS-HF-BT12", family: .other),
        .init(productID: 0x8EB0, name: "FS-BT12", family: .other),
        .init(productID: 0x8ED0, name: "FS-ST16", family: .st16),
        .init(productID: 0x8F00, name: "FS-G11P-EN", family: .g11p),
        .init(productID: 0x8F01, name: "FS-G11P-ABS", family: .g11p),
        .init(productID: 0x8F02, name: "FS-G11P-CN", family: .g11p),
    ]

    public static func product(forProductID pid: UInt16) -> Product? {
        all.first { $0.productID == pid }
    }

    public static func name(forProductID pid: UInt16) -> String {
        product(forProductID: pid)?.name ?? String(format: "unknown transmitter (0x%04X)", pid)
    }

    public enum Compatibility: Sendable, Equatable {
        /// Same product: the vendor tool imports without asking.
        case same
        /// Different product in the same family: the vendor tool asks for confirmation.
        case sameFamily
        /// The vendor tool refuses.
        case incompatible
    }

    public static func compatibility(fileProductID: UInt16, deviceProductID: UInt16) -> Compatibility {
        if fileProductID == deviceProductID { return .same }
        guard let f = product(forProductID: fileProductID), let d = product(forProductID: deviceProductID),
              f.family == d.family, f.family != .other else { return .incompatible }
        return .sameFamily
    }
}
