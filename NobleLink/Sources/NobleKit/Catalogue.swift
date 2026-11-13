import Foundation

/// Where FlySky publishes firmware. There are two independent channels and
/// they are not kept in step:
///
/// * **The downloads page** on flysky-cn.com (e.g. `noble-nb4plus-downloads`),
///   with one Windows updater `.exe` per build. This is the one FlySky keeps
///   current: in November 2026 it listed 1.0.31.
/// * **FlySky Assistant's device catalogue** (below). In November 2026 it still
///   stopped at 1.0.22.
///
/// FlySky Assistant's catalogue:
///
/// 1. `GET <server>index.php?g=App&m=yaokong&a=login&username=&yzm=&nologin=1`
///    returns JSON whose `data` object maps configuration file names to
///    `{ "md5": …, "url": … }`.
/// 2. `OnlineDevice.ini` (GBK text) has one `[DirectN]` section per transmitter
///    with `name=` and numbered `binK=` / `falshK=` / `helpK=` / `downK=` URLs,
///    newest first. `bin` is the firmware, `falsh` (sic) the resource image.
///
/// Nothing about the user or the transmitter is sent: the request is the
/// anonymous one the vendor tool makes at start-up.
public enum Catalogue {
    /// The vendor tool calls these "SEVER A" and "SEVER B". A is hosted in China
    /// and is often unreachable from elsewhere; B is the international mirror.
    public static let servers = [
        "http://enyaokongguanjia.maxhom.cn/",
        "http://aaa.flyskytech.com:88/",
    ]

    public struct Release: Sendable, Equatable {
        public enum Source: String, Sendable {
            case website = "FlySky website"
            case assistantCatalogue = "FlySky Assistant catalogue"
        }

        /// Position in the listing (1 = first listed, normally the newest).
        public var index: Int
        public var version: String?
        /// "FCC" or "STD" (FlySky's names for the two builds of each release).
        public var variant: String
        /// For the website: a Windows updater `.exe` holding both images.
        /// For the catalogue: the firmware `.bin`.
        public var firmwareURL: URL?
        /// Catalogue only: the resource image.
        public var resourceURL: URL?
        public var notesURL: URL?
        public var source: Source = .assistantCatalogue

        public var title: String {
            let v = version ?? "unknown version"
            return variant.isEmpty ? v : "\(v) \(variant)"
        }
    }

    /// Releases from every channel, website first, numbered 1… in that order.
    public struct Listing: Sendable {
        public var releases: [Release]
        /// Channels that could not be read, with the reason.
        public var failures: [(Release.Source, String)]

        public var newestVersion: String? {
            releases.compactMap(\.version).max { (Catalogue.compare($0, $1) ?? 0) < 0 }
        }
    }

    public enum CatalogueError: Error, CustomStringConvertible {
        case unreachable(String)
        case malformed(String)
        case productNotListed(String)

        public var description: String {
            switch self {
            case let .unreachable(m): return "FlySky's update servers could not be reached (\(m))."
            case let .malformed(m): return "FlySky's update server sent something unexpected: \(m)"
            case let .productNotListed(p): return "\"\(p)\" is not in FlySky's firmware catalogue."
            }
        }
    }

    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.replacingOccurrences(of: " ", with: "%20"))
    }

    static func fetch(_ url: URL, timeout: TimeInterval) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("NobleLink", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(CatalogueError.unreachable("no response"))
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(CatalogueError.unreachable(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(CatalogueError.unreachable("HTTP \(http.statusCode) from \(url.host ?? "server")"))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }
        task.resume()
        done.wait()
        return try result.get()
    }

    /// File name → download URL, from the first server that answers.
    public static func fetchIndex(timeout: TimeInterval = 15) throws -> [String: URL] {
        var lastError: Error = CatalogueError.unreachable("no server tried")
        for server in servers {
            do {
                guard let url = URL(string: server + "index.php?g=App&m=yaokong&a=login&username=&yzm=&nologin=1&lang=en") else { continue }
                let data = try fetch(url, timeout: timeout)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let entries = root["data"] as? [String: Any] else {
                    throw CatalogueError.malformed("index is not the expected JSON")
                }
                var out: [String: URL] = [:]
                for (name, value) in entries {
                    if let entry = value as? [String: Any], let text = entry["url"] as? String, let u = Catalogue.url(from: text) {
                        out[name] = u
                    }
                }
                guard !out.isEmpty else { throw CatalogueError.malformed("index lists no files") }
                return out
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Parse `OnlineDevice.ini` and return the releases listed for one product name.
    public static func releases(inCatalogue ini: Data, productName: String) throws -> [Release] {
        // Keys, names and URLs are ASCII; only comments are GBK, so Latin-1 is a safe decoding.
        let text = String(decoding: ini, as: UTF8.self).contains("[Direct")
            ? String(decoding: ini, as: UTF8.self)
            : (String(data: ini, encoding: .isoLatin1) ?? "")
        var sections: [[String: String]] = []
        var current: [String: String]?
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.isEmpty { continue }
            if line.hasPrefix("[") {
                if let c = current { sections.append(c) }
                current = line.hasPrefix("[Direct") && line != "[Direct]" ? [:] : nil
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            current?[key] = value
        }
        if let c = current { sections.append(c) }
        guard !sections.isEmpty else { throw CatalogueError.malformed("device catalogue has no product sections") }
        guard let section = sections.first(where: { $0["name"]?.caseInsensitiveCompare(productName) == .orderedSame }) else {
            throw CatalogueError.productNotListed(productName)
        }
        var out: [Release] = []
        var k = 1
        while let bin = section["bin\(k)"] {
            if !bin.isEmpty {
                let file = bin.split(separator: "/").last.map(String.init) ?? bin
                out.append(Release(index: k, version: version(inFileName: file),
                                   variant: file.uppercased().contains("FCC") ? "FCC" : "STD",
                                   firmwareURL: url(from: bin), resourceURL: url(from: section["falsh\(k)"] ?? ""),
                                   notesURL: url(from: section["help\(k)"] ?? "")))
            }
            k += 1
        }
        return out
    }

    /// "Noble Plus-EN V1.0.22FCC.bin" → "1.0.22"
    static func version(inFileName name: String) -> String? {
        guard let r = name.range(of: #"V\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(name[r].dropFirst())
    }

    public static func fetchReleases(productName: String, timeout: TimeInterval = 15) throws -> [Release] {
        let index = try fetchIndex(timeout: timeout)
        guard let iniURL = index["OnlineDevice.ini"] else { throw CatalogueError.malformed("index has no OnlineDevice.ini") }
        return try releases(inCatalogue: try fetch(iniURL, timeout: timeout * 2), productName: productName)
    }

    // MARK: The downloads page

    /// Product (as `Products` names it) → downloads page and the region label
    /// FlySky uses on it.
    public static let downloadPages: [String: (page: URL, region: String)] = [
        "Noble plus EN": (URL(string: "https://www.flysky-cn.com/noble-nb4plus-downloads")!, "EN"),
        "Noble plus EU": (URL(string: "https://www.flysky-cn.com/noble-nb4plus-downloads")!, "EU"),
    ]

    /// Read the firmware entries from a downloads page. Each file link on the page
    /// just says "DOWNLOAD"; its meaning is the label that precedes it, e.g.
    /// "FCC Firmware v1.0.31(EN version)".
    public static func releases(inDownloadsPage html: String, base: URL, region: String) -> [Release] {
        // Document order: text runs and links.
        enum Token { case text(String), link(String) }
        var tokens: [Token] = []
        let pattern = try! NSRegularExpression(pattern: #"<a\s[^>]*href=["']([^"']+)["'][^>]*>|<[^>]+>|([^<]+)"#,
                                               options: [.caseInsensitive])
        let ns = html as NSString
        for m in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                tokens.append(.link(ns.substring(with: m.range(at: 1))))
            } else if m.range(at: 2).location != NSNotFound {
                let text = ns.substring(with: m.range(at: 2))
                    .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { tokens.append(.text(text)) }
            }
        }

        let labelPattern = try! NSRegularExpression(
            pattern: #"\b(FCC|STD)\b.*?Firmware\s*v?(\d+\.\d+\.\d+).*?\((\w+)\s*version\)"#, options: [.caseInsensitive])
        var out: [Release] = []
        var pendingLabel: (variant: String, version: String, region: String)?
        var notes: URL?
        var lastText = ""
        for token in tokens {
            switch token {
            case let .text(t):
                lastText = t
                let r = NSRange(location: 0, length: (t as NSString).length)
                if let m = labelPattern.firstMatch(in: t, range: r) {
                    let sub = { (i: Int) in (t as NSString).substring(with: m.range(at: i)) }
                    pendingLabel = (sub(1).uppercased(), sub(2), sub(3).uppercased())
                }
            case let .link(href):
                guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
                let path = url.path.lowercased()
                if path.hasSuffix(".pdf"), lastText.lowercased().contains("release notes") || path.contains("release_notes") {
                    notes = notes ?? url
                } else if path.hasSuffix(".exe"), let label = pendingLabel {
                    if label.region == region.uppercased() {
                        out.append(Release(index: 0, version: label.version, variant: label.variant,
                                           firmwareURL: url, resourceURL: nil, notesURL: nil, source: .website))
                    }
                    pendingLabel = nil
                }
            }
        }
        for i in out.indices { out[i].notesURL = notes }
        return out
    }

    public static func fetchWebsiteReleases(productName: String, timeout: TimeInterval = 20) throws -> [Release] {
        guard let page = downloadPages[productName] else {
            throw CatalogueError.productNotListed("\(productName) (no known FlySky downloads page)")
        }
        let data = try fetch(page.page, timeout: timeout)
        let html = String(decoding: data, as: UTF8.self)
        let found = releases(inDownloadsPage: html, base: page.page, region: page.region)
        guard !found.isEmpty else {
            throw CatalogueError.malformed("the downloads page lists no firmware for the \(page.region) version "
                + "(the page layout may have changed)")
        }
        return found
    }

    /// Both channels. Either may fail; the listing says which did.
    public static func fetchAll(productName: String) -> Listing {
        var releases: [Release] = []
        var failures: [(Release.Source, String)] = []
        do { releases += try fetchWebsiteReleases(productName: productName) }
        catch { failures.append((.website, "\(error)")) }
        do { releases += try fetchReleases(productName: productName) }
        catch { failures.append((.assistantCatalogue, "\(error)")) }
        for i in releases.indices { releases[i].index = i + 1 }
        return Listing(releases: releases, failures: failures)
    }

    /// Download a website release (a Windows updater) and verify its contents.
    public static func downloadUpdater(_ release: Release, timeout: TimeInterval = 30) throws -> (data: Data, package: FirmwarePackage) {
        guard let url = release.firmwareURL else { throw CatalogueError.malformed("release has no download link") }
        let data = try fetch(url, timeout: timeout)
        guard data.count > 0x40, data[0] == 0x4D, data[1] == 0x5A else {
            throw CatalogueError.malformed("the download is not a Windows updater program")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("noblelink_\(UUID().uuidString).exe")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var package = try FirmwarePackage.load(url: tmp)
        package.source = suggestedFileName(release)
        return (data, package)
    }

    /// A tidy file name for a downloaded updater ("Flysky_Noble_plus_EN_1.0.31_FCC.exe").
    public static func suggestedFileName(_ release: Release, product: String = "Noble_plus_EN") -> String {
        "Flysky_\(product.replacingOccurrences(of: " ", with: "_"))_\(release.version ?? "unknown")_\(release.variant).exe"
    }

    /// Download both images of a release. `timeout` is the longest tolerated
    /// stall, not a limit on the whole download.
    ///
    /// The files live on the hosts named in the catalogue (currently
    /// `aaa.flyskytech.com:90`), which are often unreachable from outside China.
    /// The international mirror answers every path with an HTML page, so it is
    /// not a usable fallback; HTML replies are rejected here for that reason.
    public static func download(_ release: Release, timeout: TimeInterval = 20) throws -> FirmwarePackage {
        if release.source == .website { return try downloadUpdater(release, timeout: timeout).package }
        guard let fwURL = release.firmwareURL else { throw CatalogueError.malformed("release has no firmware URL") }
        func binary(_ url: URL) throws -> Data {
            let data = try fetch(url, timeout: timeout)
            if data.prefix(64).contains(UInt8(ascii: "<")), data.prefix(512).range(of: Data("html".utf8)) != nil {
                throw CatalogueError.unreachable("\(url.host ?? "server") returned a web page instead of the file")
            }
            return data
        }
        let firmware = FirmwareImage(data: try binary(fwURL))
        let resource = try release.resourceURL.map { try binary($0) }
        return FirmwarePackage(firmware: firmware, resource: resource,
                               source: fwURL.lastPathComponent.removingPercentEncoding ?? fwURL.lastPathComponent)
    }

    /// -1, 0, 1 for dotted version strings; nil when either cannot be parsed.
    public static func compare(_ a: String, _ b: String) -> Int? {
        let x = a.split(separator: ".").map { Int($0) }, y = b.split(separator: ".").map { Int($0) }
        guard !x.isEmpty, x.count == y.count, !x.contains(nil), !y.contains(nil) else { return nil }
        for (p, q) in zip(x, y) where p! != q! { return p! > q! ? 1 : -1 }
        return 0
    }
}
