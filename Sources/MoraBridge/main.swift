import Foundation
import FinanceCore

func runningMoraApps() throws -> [(pid: Int32, launch: TimeInterval)] {
    let inspection = Process(); let output = Pipe()
    inspection.executableURL = URL(fileURLWithPath: "/bin/ps")
    inspection.arguments = ["-axo", "pid=,etime=,comm="]
    inspection.standardOutput = output; inspection.standardError = FileHandle.nullDevice
    do { try inspection.run() }
    catch { throw LedgerError.invalid("MCP не смог проверить совместимость открытой Mora. Запустите сервер вне изолированной среды без доступа к процессам.") }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    inspection.waitUntilExit()
    guard inspection.terminationStatus == 0 else { throw LedgerError.invalid("Не удалось проверить запущенные экземпляры Mora.") }
    let now = Date().timeIntervalSince1970
    var applications: [(pid: Int32, launch: TimeInterval)] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard fields.count == 3, let pid = Int32(fields[0]),
              URL(fileURLWithPath: String(fields[2]).trimmingCharacters(in: .whitespaces)).lastPathComponent == "Mora" else { continue }
        let duration = fields[1].split(separator: "-")
        let days = duration.count == 2 ? Double(duration[0]) : 0
        let clock = duration.last!.split(separator: ":").compactMap { Double($0) }
        guard let days, clock.count == 2 || clock.count == 3 else { throw LedgerError.invalid("Не удалось проверить время запуска Mora.") }
        let seconds = clock.reversed().enumerated().reduce(days * 86_400) { $0 + $1.element * pow(60, Double($1.offset)) }
        applications.append((pid, now - seconds))
    }
    return applications
}

let args = CommandLine.arguments
let directory: URL
if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) { directory = URL(fileURLWithPath: args[i + 1]) }
else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mora") }
let backend = MoraAutomation(fileURL: directory.appendingPathComponent("ledger.json"))
do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 3_000_000, let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let command = input["command"] as? String else { throw LedgerError.invalid("Некорректный запрос.") }
    let arguments = input["arguments"] as? [String: Any] ?? [:]
    let readOnly = ["context", "preview_entries", "list_entries", "monthly_summary"].contains(command) || (["import_csv", "reassign_entries"].contains(command) && (arguments["dry_run"] as? Bool ?? true))
    let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mora")
    if !readOnly, directory.standardizedFileURL == defaultDirectory.standardizedFileURL {
        for app in try runningMoraApps() {
            let marker = directory.appendingPathComponent("mcp-app-\(app.pid).json")
            let contents = (try? Data(contentsOf: marker)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let contents, contents["protocol"] as? Int == 4,
                  abs((contents["launch_time"] as? Double ?? -1) - app.launch) < 10 else {
                throw LedgerError.invalid("Открыта старая версия Mora без поддержки MCP. Закройте ее и запустите обновленное приложение, чтобы сохранить данные без потерь.")
            }
        }
    }
    let response = try await backend.runJSONAsync(command, arguments: arguments)
    FileHandle.standardOutput.write(response + Data("\n".utf8))
} catch {
    let response = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription], options: [.sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(response + Data("\n".utf8))
    exit(1)
}
