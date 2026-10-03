import Foundation
import SwiftData

/// The `/refdata` catalogues, cached (§8.2, §8.3): the body exactly as the server sent it,
/// plus its `version`, which goes back out as `?version=` so an unchanged catalogue costs a
/// `304` and no body.
///
/// The raw bytes rather than a decoded copy, so the store keeps the server's shape and
/// `EvaRefData`'s decoder stays the only reader of it — a second schema here would be a
/// second thing to migrate whenever the catalogue grows a field.
@Model
final class LocalRefdata {
    var version: String
    var data: Data

    init(version: String, data: Data) {
        self.version = version
        self.data = data
    }
}
