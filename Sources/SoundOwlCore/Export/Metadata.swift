import AVFoundation

/// Carries title, artist, album, track number and artwork from the original to the export.
///
/// Sources come with ID3 (MP3), iTunes (M4A) or no tags at all. Everything is read through its
/// common or format identifier and rewritten in the iTunes key space, which is what M4A holds.
enum Metadata {
    static func items(from source: URL) async -> [AVMetadataItem] {
        guard let all = try? await AVURLAsset(url: source).load(.metadata) else { return [] }
        var out = [AVMetadataItem]()
        var seen = Set<AVMetadataIdentifier>()

        func add(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            guard let value, !seen.contains(identifier) else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            out.append(item)
            seen.insert(identifier)
        }

        for item in all {
            let common = item.commonKey
            let id = item.identifier
            switch (common, id) {
            case (.commonKeyTitle?, _):
                await add(.iTunesMetadataSongName, try? item.load(.stringValue) as NSString?)
            case (.commonKeyArtist?, _):
                await add(.iTunesMetadataArtist, try? item.load(.stringValue) as NSString?)
            case (.commonKeyAlbumName?, _):
                await add(.iTunesMetadataAlbum, try? item.load(.stringValue) as NSString?)
            case (.commonKeyArtwork?, _):
                if let data = try? await item.load(.dataValue) {
                    let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                    add(.iTunesMetadataCoverArt, data as NSData,
                        dataType: (png ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String)
                }
            case (_, .iTunesMetadataAlbumArtist?), (_, .id3MetadataBand?):
                await add(.iTunesMetadataAlbumArtist, try? item.load(.stringValue) as NSString?)
            case (_, .iTunesMetadataTrackNumber?):
                await add(.iTunesMetadataTrackNumber, try? item.load(.dataValue) as NSData?)
            case (_, .id3MetadataTrackNumber?):
                // ID3 stores "3" or "3/12"; iTunes wants (0, track, total, 0) as big-endian UInt16s.
                if let text = try? await item.load(.stringValue) {
                    let parts = text.split(separator: "/").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
                    if let track = parts.first {
                        let words: [UInt16] = [0, track, parts.count > 1 ? parts[1] : 0, 0]
                        let data = words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
                        add(.iTunesMetadataTrackNumber, Data(data) as NSData)
                    }
                }
            default:
                break
            }
        }
        return out
    }
}
