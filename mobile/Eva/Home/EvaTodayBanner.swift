import Foundation

// The "Worth reading" rail, as `GET /me/today` hands it over (D7, #102).
//
// The route answers `banners: [{ id, title, meta, url }]` beside the card: zero to three
// items in display order, always present, chosen once with the card and stored in the same
// daily document — so the rail follows the card's rule and does not change on a refresh.
// ARCHITECTURE §4 (`GET /me/today`) is the contract; `api/src/today.ts` `TodayBanner` is
// its other half.
//
// ## Decoding is lossy, per item, and that is a decision
//
// Home must never fail to draw because of the rail. So:
//
//   * `banners` missing, `null`, or not an array → no rail. An older API, or a document
//     stored before D7, has no key at all, and that is "nothing to read" rather than a
//     broken day.
//   * An item that does not decode, has an empty title, or whose `url` is not an absolute
//     `https://` URL with a host is **dropped**, and the rest of the rail is kept. The
//     server already refuses to select such a row, so reaching this branch means the
//     contract was broken upstream; dropping the one item shows every item that is sound,
//     where rejecting the whole payload would take the card down with it.
//   * `https` only, deliberately, and not merely "a URL". The rail opens its link in
//     `SFSafariViewController`, which raises an exception for any scheme other than
//     `http`/`https` — a `javascript:` or `eva://` value would crash the app rather than
//     fail to load. `http` is refused too: the contract says `https`, and an article about
//     someone's cycle has no business travelling in the clear.
//   * A repeated `id` keeps its first occurrence. The rail is a `ForEach` over ids, and
//     two items with one id would be drawn as one view with the other's words.
//
// Nothing here is logged. Which article a user was offered is derived from her card's
// subject and her focus areas (api/src/today.ts says the same about the banner id).

/// One item on the Home tab's "Worth reading" rail.
struct EvaTodayBanner: Equatable, Sendable, Identifiable {
    /// The `content/` banner id — permanent and opaque. Also the accessibility identifier's
    /// suffix, so it has to be stable across opens, which the server's document makes it.
    let id: String
    let title: String
    /// Category and reading time, as the reviewed copy writes it: "Nutrition · 4 min read".
    let meta: String
    /// The article. Always absolute `https://` — see the file comment.
    let url: URL

    /// `nil` unless `url` is one the rail may open.
    init?(id: String, title: String, meta: String, url: URL) {
        guard !title.isEmpty, Self.isOpenable(url) else { return nil }
        self.id = id
        self.title = title
        self.meta = meta
        self.url = url
    }

    /// Absolute, `https`, with a host. `SFSafariViewController` accepts nothing else safely.
    static func isOpenable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host() ?? "").isEmpty
    }

    /// What VoiceOver reads for the item: the title, then the meta line (#102).
    ///
    /// A comma rather than a full stop between them: the meta is a label on the title
    /// ("Nutrition · 4 min read"), not a second sentence, and the comma is the pause
    /// VoiceOver puts between combined children anyway.
    var accessibilityLabel: String {
        meta.isEmpty ? title : "\(title), \(meta)"
    }
}

extension EvaTodayBanner: Decodable {
    private enum CodingKeys: String, CodingKey { case id, title, meta, url }

    /// Strict for one item — the lossy part is `EvaTodayBanner.rail(from:)`, which drops an
    /// item that throws here.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let meta = try container.decode(String.self, forKey: .meta)
        let raw = try container.decode(String.self, forKey: .url)
        guard let url = URL(string: raw),
              let banner = EvaTodayBanner(id: id, title: title, meta: meta, url: url)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .url, in: container,
                debugDescription: "A banner needs a title and an absolute https URL"
            )
        }
        self = banner
    }
}

extension EvaTodayBanner {

    /// Decodes `banners` from the `/me/today` body, item by item — see the file comment
    /// for what is dropped and why. Never throws: the worst case is an empty rail.
    static func rail<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [EvaTodayBanner] {
        guard let items = try? container.decodeIfPresent([Lossy].self, forKey: key) else {
            return []
        }
        var seen = Set<String>()
        return items.compactMap(\.banner).filter { seen.insert($0.id).inserted }
    }

    /// One array element that may or may not be a banner. Decoding it never throws, so one
    /// bad item cannot fail the array — and with it the whole day's document.
    private struct Lossy: Decodable {
        let banner: EvaTodayBanner?

        init(from decoder: any Decoder) throws {
            banner = try? EvaTodayBanner(from: decoder)
        }
    }
}
