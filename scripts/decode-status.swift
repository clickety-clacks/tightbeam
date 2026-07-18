import Foundation
let data = FileManager.default.contents(atPath: "/tmp/status.json")!
let dec = JSONDecoder()
dec.dateDecodingStrategy = .millisecondsSince1970
do {
    let s = try dec.decode(SessionStatus.self, from: data)
    print("DECODE OK: model=\(s.display.model ?? "nil") harness=\(s.display.harness ?? "nil") catalog=\(s.modelCatalog?.models.count ?? -1)")
} catch {
    print("DECODE FAILED: \(error)")
}
