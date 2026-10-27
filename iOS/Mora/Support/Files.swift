import SwiftUI
import UniformTypeIdentifiers

/// In-memory export for `fileExporter`: CSV operations and JSON backups.
struct DataDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json, .plainText]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ExportFile {
    var document: DataDocument
    var name: String
    var type: UTType = .commaSeparatedText
}
